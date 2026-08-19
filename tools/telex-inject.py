#!/usr/bin/env python3
# Guest-side evdev key injector for measuring/exercising the ash Vietnamese IME.
#
# CDP Input.dispatchKeyEvent injects into the *renderer*, downstream of ash's
# input method, so it never exercises the Telex engine. Real physical-key
# events enter ozone -> ash InputMethod -> the IME (component-extension JS or
# the mojo RuleBasedEngine) -> composition back to the focused web contents.
# The only way in from outside is a real evdev device, so this creates a uinput
# keyboard and types through it.
#
# Usage:
#   telex-inject.py [--pre-delay MS] [--key-delay MS] TOKEN...
# Tokens:
#   a..z            a letter
#   SPACE           space
#   CTRL+SPACE      ctrl-space chord (ChromeOS "switch to last IME")
#   CTRL+SHIFT+SPACE next-IME chord
#   a string of bare letters like "tieengs" is also accepted as one token and
#   is expanded left-to-right.
import ctypes, fcntl, os, struct, sys, time

# ---- uinput / input-event-codes constants ----
EV_SYN, EV_KEY = 0x00, 0x01
SYN_REPORT = 0
UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY= 0x5502

KEY = {
 'a':30,'b':48,'c':46,'d':32,'e':18,'f':33,'g':34,'h':35,'i':23,'j':36,'k':37,
 'l':38,'m':50,'n':49,'o':24,'p':25,'q':16,'r':19,'s':31,'t':20,'u':22,'v':47,
 'w':17,'x':45,'y':21,'z':44,'SPACE':57,'CTRL':29,'SHIFT':42,'ENTER':28,
 # Number row (VNI encodes tones as digits) and the unshifted punctuation the
 # VIQR/TCVN layouts key their diacritics off of.
 '1':2,'2':3,'3':4,'4':5,'5':6,'6':7,'7':8,'8':9,'9':10,'0':11,
 '.':52,"'":40,'`':41,';':39,'-':12,'=':13,'[':26,']':27,',':51,'/':53,'\\':43,
}
ALLKEYS = sorted(set(KEY.values()))

def emit(fd, etype, code, val):
    # struct input_event: timeval{long,long}, u16 type, u16 code, s32 value
    os.write(fd, struct.pack('llHHi', 0, 0, etype, code, val))

def syn(fd):
    emit(fd, EV_SYN, SYN_REPORT, 0)

def main():
    args = sys.argv[1:]
    pre_delay = 0.8
    key_delay = 0.06
    toks = []
    i = 0
    while i < len(args):
        if args[i] == '--pre-delay': pre_delay = float(args[i+1])/1000.0; i += 2; continue
        if args[i] == '--key-delay': key_delay = float(args[i+1])/1000.0; i += 2; continue
        # --file PATH: read whitespace-separated tokens from a file. Punctuation
        # like ' ` ? ~ (which VIQR/TCVN key their diacritics off of) cannot
        # survive host->ssh->guest shell quoting as argv, so the harness stages
        # the input in a file and points here.
        if args[i] == '--file':
            with open(args[i+1]) as fh:
                toks.extend(fh.read().split())
            i += 2; continue
        toks.append(args[i]); i += 1

    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for k in ALLKEYS:
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    # struct uinput_user_dev: char name[80]; input_id{u16 x4}; u32 ff_effects_max; abs arrays
    name = b'telex-inject'.ljust(80, b'\x00')
    uidev = name + struct.pack('HHHH', 0x03, 0x1234, 0x5678, 1) + struct.pack('i', 0)
    uidev += struct.pack('i'*64, *([0]*64))  # absmax
    uidev += struct.pack('i'*64, *([0]*64))  # absmin
    uidev += struct.pack('i'*64, *([0]*64))  # absfuzz
    uidev += struct.pack('i'*64, *([0]*64))  # absflat
    os.write(fd, uidev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(pre_delay)  # let ash enumerate the new device

    def press(code):
        emit(fd, EV_KEY, code, 1); syn(fd)
    def release(code):
        emit(fd, EV_KEY, code, 0); syn(fd)
    def tap(code):
        press(code); time.sleep(0.008); release(code)
    def shifted_tap(code):
        press(KEY['SHIFT']); time.sleep(0.005)
        press(code); time.sleep(0.008); release(code)
        time.sleep(0.005); release(KEY['SHIFT'])

    # Shifted characters -> the base key that produces them with SHIFT held.
    # VIQR keys its diacritics off ? (hook), ~ (tilde), ^ (circumflex),
    # + (horn), ( (breve); support them plus uppercase letters.
    SHIFTED = {
        '?':'/', '~':'`', '^':'6', '+':'=', '(':'9', ')':'0', '_':'-',
        '!':'1', '@':'2', '#':'3', '$':'4', '%':'5', '*':'8', ':':';',
        '<':',', '>':'.', '{':'[', '}':']', '|':'\\', '"':"'",
    }

    def expand(tok):
        if tok == 'SPACE': return [('tap', KEY['SPACE'])]
        if tok == 'ENTER': return [('tap', KEY['ENTER'])]
        if tok == 'CTRL+SPACE':
            return [('chord', [KEY['CTRL'], KEY['SPACE']])]
        if tok == 'CTRL+SHIFT+SPACE':
            return [('chord', [KEY['CTRL'], KEY['SHIFT'], KEY['SPACE']])]
        out = []
        for ch in tok:
            if ch in KEY:
                out.append(('tap', KEY[ch]))
            elif ch in SHIFTED and SHIFTED[ch] in KEY:
                out.append(('shifted', KEY[SHIFTED[ch]]))
            elif ch.isupper() and ch.lower() in KEY:
                out.append(('shifted', KEY[ch.lower()]))
        return out

    for tok in toks:
        for kind, payload in expand(tok):
            if kind == 'tap':
                tap(payload)
            elif kind == 'shifted':
                shifted_tap(payload)
            elif kind == 'chord':
                for c in payload: press(c); time.sleep(0.005)
                for c in reversed(payload): release(c); time.sleep(0.005)
            time.sleep(key_delay)

    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)

if __name__ == '__main__':
    main()
