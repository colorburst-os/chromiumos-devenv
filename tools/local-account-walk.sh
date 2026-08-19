#!/bin/bash
# Walk the OOBE local-account flow by clicking the real UI over CDP.
# No Oobe.loginForTesting / OobeAPI.advanceToScreen is used to create the
# account -- every step below is a click on, or a keystroke into, an element a
# user would touch. OobeAPI is used only to *read* the current screen name.
#
# Usage: local-account-walk.sh <name> <password>
set -u
NAME="${1:-alex}"
PW="${2:-colorburst-test-1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C() { "$DIR/tools/cdp.py" --target chrome://oobe eval "$1" 2>&1 | tail -1; }
S() { C 'OobeAPI.getCurrentScreenName()'; }
click() { # click <screen-id> <selector>
  C "(()=>{const s=document.getElementById('$1');if(!s)return 'no screen';
      const e=s.shadowRoot.querySelector('$2');if(!e)return 'no element';
      e.click();return 'ok';})()"
}
waitfor() { # waitfor <screen-id> [tries]
  local n=${2:-30}
  for _ in $(seq 1 "$n"); do
    [ "$(S)" = "\"$1\"" ] && { echo "  -> $1"; return 0; }
    sleep 2
  done
  echo "  !! timed out waiting for $1 (now $(S))"; return 1
}

echo "start: $(S)"
echo "welcome:      $(C '(()=>{const w=document.getElementById("connect").shadowRoot.querySelector("oobe-welcome-dialog");w.shadowRoot.querySelector("#getStarted").click();return "ok";})()')"
sleep 4
if [ "$(S)" = '"os-trial"' ]; then
  echo "os-trial try: $(click os-trial '#tryButton')"; sleep 2
  echo "os-trial next:$(click os-trial '#nextButton')"; sleep 5
fi
waitfor user-creation || exit 1

echo "cards: $(C '(()=>{const r=document.getElementById("user-creation").shadowRoot;
  return Array.from(r.querySelectorAll("cr-card-radio-button")).map(e=>e.id+(e.hidden?":HIDDEN":":shown")).join(" ");})()')"
echo "pick local:   $(click user-creation '#localAccountButton')"; sleep 2
echo "next:         $(click user-creation '#nextButton')"; sleep 4
waitfor local-account || exit 1

# The screen now collects name + password + confirm; the account is created
# WITH its local-password factor in one step (no local-password-setup screen
# afterwards -- seeing one is a failure).
type_into() { # type_into <selector> <text>
  C "(()=>{document.getElementById('local-account').shadowRoot.querySelector('$1').focus();return 'ok';})()" >/dev/null
  "$DIR/tools/cdp.py" --target chrome://oobe send Input.insertText \
      "{\"text\":\"$2\"}" >/dev/null 2>&1
  sleep 1
}
type_into '#nameInput' "$NAME"
type_into '#passwordInput' "$PW"
type_into '#confirmInput' "$PW"
echo "typed:        $(C '(()=>{const r=document.getElementById("local-account").shadowRoot;
  return "name="+r.querySelector("#nameInput").value+
         " pw_len="+r.querySelector("#passwordInput").value.length+
         " confirm_len="+r.querySelector("#confirmInput").value.length;})()')"
echo "next:         $(click local-account '#nextButton')"
sleep 8
echo "screen now:   $(S)"

# Remaining onboarding screens are all Next/Done. The two password screens
# must NOT appear any more: the factor already exists.
for _ in $(seq 1 25); do
  cur=$(S | tr -d '"')
  [ -z "$cur" ] && { echo "OOBE finished -- session started"; break; }
  case "$cur" in
    local-password-setup|password-selection)
      echo "FAIL: reached $cur -- the factor was not created at signup"; exit 1;;
  esac
  echo "  $cur"
  C "(()=>{const s=document.getElementById('$cur');if(!s||!s.shadowRoot)return 'n/a';
      for (const sel of ['#nextButton','#doneButton','#acceptButton',
                         '#setupSkipButton','#skipButton','oobe-next-button',
                         'oobe-text-button']) {
        const e=s.shadowRoot.querySelector(sel);
        if (e && !e.hidden && !e.disabled) { e.click(); return 'clicked '+sel; }
      } return 'no button';})()" >/dev/null
  sleep 5
done
