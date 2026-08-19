#!/usr/bin/env python3
"""Minimal Chrome DevTools Protocol client (stdlib only).

Talks to a chrome --remote-debugging-port over an SSH tunnel. No pip deps:
implements just enough RFC6455 (client masking, text frames) to drive CDP.

  ./tools/cdp.py list
  ./tools/cdp.py eval 'document.title'
  ./tools/cdp.py eval --target 'chrome://oobe' 'location.href'
  ./tools/cdp.py screenshot out.png
  ./tools/cdp.py send Page.navigate '{"url":"chrome://version"}'

--port defaults to 9229 (see VM-INTROSPECTION.md for the tunnel).
"""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import urllib.request


def http_json(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as r:
        return json.load(r)


class WS:
    """Blocking, single-threaded websocket client. Text frames only."""

    def __init__(self, url):
        _, _, rest = url.partition("://")
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self.buf += self._recv()
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError(head.decode(errors="replace"))
        self.msg_id = 0

    def _recv(self):
        d = self.sock.recv(65536)
        if not d:
            raise RuntimeError("websocket closed")
        return d

    def _need(self, n):
        while len(self.buf) < n:
            self.buf += self._recv()

    def send(self, obj):
        payload = json.dumps(obj).encode()
        n = len(payload)
        if n < 126:
            hdr = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 65536:
            hdr = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            hdr = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + mask + masked)

    def recv(self):
        # Reassembles fragmented messages: big payloads (a screenshot, say) can
        # arrive as an unFINished text frame followed by continuation frames.
        frags = b""
        while True:
            self._need(2)
            b0, b1 = self.buf[0], self.buf[1]
            fin, opcode, n, off = b0 & 0x80, b0 & 0x0F, b1 & 0x7F, 2
            if n == 126:
                self._need(4)
                n, off = struct.unpack("!H", self.buf[2:4])[0], 4
            elif n == 127:
                self._need(10)
                n, off = struct.unpack("!Q", self.buf[2:10])[0], 10
            self._need(off + n)
            data, self.buf = self.buf[off:off + n], self.buf[off + n:]
            if opcode == 0x8:
                raise RuntimeError("websocket close frame")
            if opcode in (0x9, 0xA):
                continue  # ping/pong: ignore, and don't disturb reassembly
            if opcode == 0x0:
                frags += data          # continuation
            elif opcode in (0x1, 0x2):
                frags = data           # start of a new message
            else:
                continue
            if fin:
                return json.loads(frags)

    def call(self, method, params=None):
        self.msg_id += 1
        mid = self.msg_id
        self.send({"id": mid, "method": method, "params": params or {}})
        while True:
            m = self.recv()
            if m.get("id") == mid:
                if "error" in m:
                    raise RuntimeError(json.dumps(m["error"]))
                return m.get("result", {})


def pick_target(port, match):
    targets = http_json(port, "/json/list")
    cands = [t for t in targets if t.get("webSocketDebuggerUrl")]
    if match:
        cands = [t for t in cands if match in t.get("url", "") or match in t.get("title", "")]
    else:
        cands = [t for t in cands if t.get("type") == "page"] or cands
    if not cands:
        sys.exit(f"no CDP target matching {match!r}")
    return cands[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9229)
    ap.add_argument("--target", default=None, help="substring of target url/title")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("eval"); p.add_argument("expr")
    p = sub.add_parser("screenshot"); p.add_argument("out")
    p = sub.add_parser("send"); p.add_argument("method"); p.add_argument("params", nargs="?", default="{}")
    a = ap.parse_args()

    if a.cmd == "list":
        for t in http_json(a.port, "/json/list"):
            print(f"{t.get('type'):10} {t.get('url','')[:100]}\n           {t.get('webSocketDebuggerUrl','')}")
        return

    ws = WS(pick_target(a.port, a.target)["webSocketDebuggerUrl"])
    if a.cmd == "eval":
        r = ws.call("Runtime.evaluate", {
            "expression": a.expr, "returnByValue": True, "awaitPromise": True})
        res = r.get("result", {})
        if "exceptionDetails" in r:
            sys.exit(json.dumps(r["exceptionDetails"], indent=2))
        print(json.dumps(res.get("value", res.get("description")), indent=2, ensure_ascii=False))
    elif a.cmd == "screenshot":
        r = ws.call("Page.captureScreenshot", {"format": "png"})
        open(a.out, "wb").write(base64.b64decode(r["data"]))
        print(f"wrote {a.out}")
    elif a.cmd == "send":
        print(json.dumps(ws.call(a.method, json.loads(a.params)), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
