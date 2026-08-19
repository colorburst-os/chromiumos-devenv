#!/usr/bin/env python3
"""Type a string on a synthetic uinput keyboard inside the guest.

Ash's login pod is a views surface, not WebUI, so CDP cannot reach it. This
creates a real kernel input device, which is indistinguishable to Chrome from
the virtio keyboard.

Usage (in the guest, as root):  guest-type.py "text to type" [--enter]
"""
import fcntl
import os
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN, EV_KEY = 0x00, 0x01
SYN_REPORT = 0
KEY_LEFTSHIFT, KEY_ENTER = 42, 28

ROW = "1234567890-="
LETTERS = {c: 30 + i for i, c in enumerate("asdfghjkl")}
LETTERS.update({c: 16 + i for i, c in enumerate("qwertyuiop")})
LETTERS.update({c: 44 + i for i, c in enumerate("zxcvbnm")})
DIGITS = {c: 2 + i for i, c in enumerate(ROW)}
PUNCT = {".": 52, ",": 51, "/": 53, ";": 39, "'": 40, "[": 26, "]": 27,
         "\\": 43, "`": 41, " ": 57}
SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
           "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
           ":": ";", '"': "'", "<": ",", ">": ".", "?": "/", "~": "`",
           "{": "[", "}": "]", "|": "\\"}


def keycode(ch):
    """Return (code, needs_shift) for a printable ASCII character."""
    if ch.isupper():
        return LETTERS[ch.lower()], True
    if ch in SHIFTED:
        return keycode(SHIFTED[ch])[0], True
    for table in (LETTERS, DIGITS, PUNCT):
        if ch in table:
            return table[ch], False
    raise ValueError("unsupported character %r" % ch)


def main():
    text = sys.argv[1]
    press_enter = "--enter" in sys.argv[2:]

    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in range(1, 128):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    # struct uinput_setup { struct input_id id; char name[80]; __u32 ff; }
    setup = struct.pack("HHHH80sI", 0x03, 0x1234, 0x5678, 1,
                        b"colorburst synthetic keyboard", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(1.0)  # let udev/Chrome notice the device

    def emit(etype, code, value):
        os.write(fd, struct.pack("llHHi", 0, 0, etype, code, value))

    def tap(code, shift=False):
        if shift:
            emit(EV_KEY, KEY_LEFTSHIFT, 1)
            emit(EV_SYN, SYN_REPORT, 0)
        emit(EV_KEY, code, 1)
        emit(EV_SYN, SYN_REPORT, 0)
        emit(EV_KEY, code, 0)
        emit(EV_SYN, SYN_REPORT, 0)
        if shift:
            emit(EV_KEY, KEY_LEFTSHIFT, 0)
            emit(EV_SYN, SYN_REPORT, 0)
        time.sleep(0.05)

    for ch in text:
        code, shift = keycode(ch)
        tap(code, shift)
    if press_enter:
        time.sleep(0.3)
        tap(KEY_ENTER)

    time.sleep(0.5)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
    print("typed %d chars%s" % (len(text), " + enter" if press_enter else ""))


if __name__ == "__main__":
    main()
