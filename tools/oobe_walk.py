#!/usr/bin/env python3
"""Drive OOBE to a logged-in local-account session, by clicking the real UI.

Used by tools/vm-session.sh; runnable on its own:

    tools/oobe_walk.py --port 9231 --name alex --password colorburst-test-1
    tools/oobe_walk.py --port 9231 --open https://example.com

Deliberate constraints, do not "simplify" them away:
  * The account is created by clicking and typing in the OOBE WebUI --
    Oobe.loginForTesting / OobeAPI.advanceToScreen would skip exactly the code
    we are trying to test. OobeAPI is used ONLY to read the current screen.
  * Every wait is a condition with a deadline; nothing sleeps blindly. On a
    timeout the error names the screen the flow is actually stuck on.

Why the reconnect logic exists: finishing OOBE tears down the chrome://oobe
web contents, so the websocket dies mid-poll. That is the success signal, not
an error -- but the same exception also means "chrome restarted under us", so
we reconnect once before concluding anything.
"""
import argparse
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cdp  # noqa: E402


class Timeout(Exception):
    pass


class Session:
    """A CDP connection to one page target, reconnecting when it goes away."""

    def __init__(self, port, match):
        self.port = port
        self.match = match
        self.ws = None
        self.connect()

    def targets(self):
        return cdp.http_json(self.port, "/json/list")

    def connect(self, timeout=60):
        end = time.time() + timeout
        last = None
        while time.time() < end:
            try:
                for t in self.targets():
                    if self.match in t.get("url", "") and t.get("webSocketDebuggerUrl"):
                        self.ws = cdp.WS(t["webSocketDebuggerUrl"])
                        return True
            except Exception as e:  # chrome still coming up
                last = e
            time.sleep(1)
        raise Timeout(f"no {self.match!r} target after {timeout}s (last error: {last})")

    def gone(self):
        """True if the target we were driving no longer exists."""
        try:
            return not any(self.match in t.get("url", "") for t in self.targets())
        except Exception:
            return False

    def ev(self, expr, retry=True):
        try:
            r = self.ws.call("Runtime.evaluate", {
                "expression": expr, "returnByValue": True, "awaitPromise": True})
        except Exception:
            if not retry:
                raise
            # The socket died. Either chrome restarted (reconnect and retry) or
            # the target is gone for good (OOBE finished) -- in which case a
            # reconnect would just burn its whole timeout, so give up quietly
            # and let the caller notice via gone().
            if self.gone():
                return None
            try:
                self.connect(timeout=30)
            except Timeout:
                return None
            return self.ev(expr, retry=False)
        if "exceptionDetails" in r:
            return None
        return r["result"].get("value")

    def send(self, method, params):
        return self.ws.call(method, params)


# --------------------------------------------------------------------- OOBE --

def screen(s):
    return s.ev("typeof OobeAPI=='object' ? OobeAPI.getCurrentScreenName() : null")


def wait_screen(s, names, timeout=120, label=None):
    """Block until getCurrentScreenName() is one of `names`."""
    if isinstance(names, str):
        names = [names]
    end = time.time() + timeout
    cur = None
    while time.time() < end:
        cur = screen(s)
        if cur in names:
            return cur
        time.sleep(1)
    raise Timeout(f"waited {timeout}s for {label or '/'.join(names)}; "
                  f"current screen is {cur!r}")


def click(s, screen_id, selector):
    """Click an element inside a screen's shadow root. Returns a status string."""
    return s.ev("""(()=>{const s=document.getElementById('%s');
        if(!s||!s.shadowRoot) return 'no screen';
        const e=s.shadowRoot.querySelector('%s');
        if(!e) return 'no element';
        if(e.hidden||e.disabled) return 'not clickable';
        e.click(); return 'ok';})()""" % (screen_id, selector))


def click_when(s, screen_id, selector, timeout=60):
    """Retry a click until the element exists and is enabled."""
    end = time.time() + timeout
    r = None
    while time.time() < end:
        r = click(s, screen_id, selector)
        if r == "ok":
            return
        time.sleep(1)
    raise Timeout(f"could not click {selector} on {screen_id}: {r} "
                  f"(screen is {screen(s)!r})")


def type_into(s, screen_id, selector, text, timeout=30):
    """Focus a field and insert text, verifying the value actually landed.

    Input.insertText goes through the real input pipeline (unlike setting
    .value, which Polymer would not see as user input).
    """
    end = time.time() + timeout
    while time.time() < end:
        s.ev("""(()=>{const r=document.getElementById('%s').shadowRoot;
            const e=r.querySelector('%s'); if(!e) return 'no'; e.focus();
            if (e.shadowRoot) { const i=e.shadowRoot.querySelector('input');
                                if (i) i.focus(); }
            return 'ok';})()""" % (screen_id, selector))
        s.send("Input.insertText", {"text": text})
        got = s.ev("""(()=>{const e=document.getElementById('%s').shadowRoot
            .querySelector('%s'); return e ? String(e.value||'') : '';})()"""
            % (screen_id, selector))
        if got == text:
            return
        # Clear whatever partially landed and try again.
        s.ev("""(()=>{const e=document.getElementById('%s').shadowRoot
            .querySelector('%s'); if(e) e.value=''; })()""" % (screen_id, selector))
        time.sleep(1)
    raise Timeout(f"could not type into {selector} on {screen_id}")


# Buttons that mean "next" on the assorted onboarding screens, in priority
# order. Anything not listed here is a screen we have not seen before -- the
# walk reports it rather than guessing.
NEXT_BUTTONS = ["#nextButton", "#doneButton", "#acceptButton", "#getStarted",
                "#setupSkipButton", "#skipButton", "oobe-next-button",
                "oobe-text-button"]

# Reaching either of these means the account was created WITHOUT its password
# factor, i.e. the single-screen local-account flow regressed.
FORBIDDEN = {"local-password-setup", "password-selection"}


def walk(s, name, password, verbose=True):
    def say(*a):
        if verbose:
            print(*a, flush=True)

    wait_screen(s, ["connect"], timeout=180, label="the welcome screen")
    say("welcome")
    # The welcome screen's button lives one shadow root deeper than the rest.
    s.ev("""(()=>{const w=document.getElementById('connect').shadowRoot
        .querySelector('oobe-welcome-dialog');
        w.shadowRoot.querySelector('#getStarted').click(); return 'ok';})()""")

    cur = wait_screen(s, ["os-trial", "user-creation", "network-selection"],
                      timeout=120, label="the screen after welcome")
    if cur == "network-selection":
        click_when(s, "network-selection", "#nextButton")
        cur = wait_screen(s, ["os-trial", "user-creation"], timeout=120)
    if cur == "os-trial":
        say("os-trial")
        click_when(s, "os-trial", "#tryButton")
        click_when(s, "os-trial", "#nextButton")
        wait_screen(s, ["user-creation"], timeout=120)

    say("user-creation")
    cards = s.ev("""(()=>{const r=document.getElementById('user-creation').shadowRoot;
        return Array.from(r.querySelectorAll('cr-card-radio-button'))
            .map(e=>e.id+(e.hidden?':HIDDEN':':shown')).join(' ');})()""")
    say("  cards:", cards)
    if "localAccountButton:shown" not in (cards or ""):
        raise SystemExit(f"local-account option is not offered (cards: {cards}) -- "
                         "is this a colorburst image?")
    click_when(s, "user-creation", "#localAccountButton")
    click_when(s, "user-creation", "#nextButton")

    wait_screen(s, ["local-account"], timeout=120)
    say("local-account: name + password + confirm on ONE screen")
    type_into(s, "local-account", "#nameInput", name)
    type_into(s, "local-account", "#passwordInput", password)
    type_into(s, "local-account", "#confirmInput", password)
    click_when(s, "local-account", "#nextButton")

    # Onboarding tail: click through whatever appears until the OOBE web
    # contents goes away, which is what "the session started" looks like.
    say("onboarding tail")
    end = time.time() + 420
    last, stuck = None, 0
    while time.time() < end:
        cur = screen(s)
        if cur in (None, "") and s.gone():
            say("OOBE finished -- session started")
            return
        if cur in FORBIDDEN:
            raise SystemExit(
                f"FAIL: reached {cur} -- the password factor was NOT created at "
                "signup; the single-screen local-account flow has regressed")
        if cur != last:
            say(" ", cur)
            last, stuck = cur, 0
        else:
            stuck += 1
            if stuck > 24:  # ~2 min on one screen with no button that works
                raise Timeout(f"stuck on screen {cur!r} for 2 minutes")
        for sel in NEXT_BUTTONS:
            if click(s, cur, sel) == "ok":
                break
        time.sleep(5)
    raise Timeout(f"onboarding did not finish in 7 minutes (screen {screen(s)!r})")


# --------------------------------------------------------------------- open --

def open_url(port, url):
    """Open a real browser tab and print the CDP target that backs it."""
    # createTarget against the browser endpoint occasionally errors if Chrome
    # is mid-navigation (e.g. a SWA still wiring up). One reconnect+retry makes
    # it deterministic.
    tid = None
    for attempt in range(3):
        try:
            ver = cdp.http_json(port, "/json/version")
            ws = cdp.WS(ver["webSocketDebuggerUrl"])
            tid = ws.call("Target.createTarget", {"url": url})["targetId"]
            break
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(1)
    end = time.time() + 60
    while time.time() < end:
        for t in cdp.http_json(port, "/json/list"):
            if t.get("id") == tid:
                # Wait for the navigation to actually commit, so the caller can
                # immediately eval against it.
                if t.get("url") not in ("", "about:blank"):
                    print(json.dumps({"targetId": tid, "url": t["url"],
                                      "title": t.get("title", ""),
                                      "ws": t.get("webSocketDebuggerUrl", "")},
                                     indent=2))
                    return
        time.sleep(1)
    raise Timeout(f"target {tid} never finished loading {url}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9229)
    ap.add_argument("--name", default="alex")
    ap.add_argument("--password", default="colorburst-test-1")
    ap.add_argument("--open", dest="open_url", default=None)
    a = ap.parse_args()
    try:
        if a.open_url:
            open_url(a.port, a.open_url)
        else:
            walk(Session(a.port, "chrome://oobe"), a.name, a.password)
    except Timeout as e:
        sys.exit(f"oobe_walk: TIMEOUT: {e}")
    except urllib.error.URLError as e:
        sys.exit(f"oobe_walk: no CDP on 127.0.0.1:{a.port} ({e}) -- is the tunnel up?")


if __name__ == "__main__":
    main()
