// SPDX-License-Identifier: LGPL-2.0-or-later
// colorburst PoC host driver: feed a Telex keystroke string to the vendored
// LGPL UkEngine and print the committed Unicode (UTF-8). This is NOT part of the
// Chrome build; it exists to prove the engine core compiles and is correct
// host-side before the mojo integration. Build with -funsigned-char.
//
// Usage: poc_driver <modernStyle> <freeMarking> <spellCheck> <autoRestore> KEYS
//   flags are 0/1; KEYS is an ASCII Telex string. A trailing '.' in KEYS is
//   sent as a word-break (space is awkward on argv) to trigger D4 restore.
#include "charset.h"
#include "inputproc.h"
#include "keycons.h"
#include "mactab.h"
#include "ukengine.h"
#include "vnlexi.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// Decode a UTF-8 byte buffer into codepoints.
static std::vector<unsigned int> decodeUtf8(const unsigned char *b, int n) {
    std::vector<unsigned int> out;
    int i = 0;
    while (i < n) {
        unsigned char c = b[i];
        unsigned int cp;
        int len;
        if (c < 0x80) { cp = c; len = 1; }
        else if ((c >> 5) == 0x6) { cp = c & 0x1F; len = 2; }
        else if ((c >> 4) == 0xE) { cp = c & 0x0F; len = 3; }
        else { cp = c & 0x07; len = 4; }
        for (int k = 1; k < len && i + k < n; k++)
            cp = (cp << 6) | (b[i + k] & 0x3F);
        out.push_back(cp);
        i += len;
    }
    return out;
}

static std::string encodeUtf8(const std::vector<unsigned int> &cps) {
    std::string s;
    for (unsigned int cp : cps) {
        if (cp < 0x80) s += (char)cp;
        else if (cp < 0x800) { s += (char)(0xC0 | (cp >> 6)); s += (char)(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { s += (char)(0xE0 | (cp >> 12)); s += (char)(0x80 | ((cp >> 6) & 0x3F)); s += (char)(0x80 | (cp & 0x3F)); }
        else { s += (char)(0xF0 | (cp >> 18)); s += (char)(0x80 | ((cp >> 12) & 0x3F)); s += (char)(0x80 | ((cp >> 6) & 0x3F)); s += (char)(0x80 | (cp & 0x3F)); }
    }
    return s;
}

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "need 5 args + keys\n"); return 2; }

    SetupUnikeyEngine();
    UkSharedMem mem;
    memset(&mem, 0, sizeof(mem));
    mem.input.init();
    mem.macStore.init();
    mem.vietKey = true;
    mem.usrKeyMapLoaded = false;
    mem.charsetId = CONV_CHARSET_XUTF8;
    mem.input.setIM(UkTelex);

    mem.options.freeMarking = atoi(argv[2]);
    mem.options.modernStyle = atoi(argv[1]);
    mem.options.macroEnabled = 0;
    mem.options.spellCheckEnabled = atoi(argv[3]);
    mem.options.autoNonVnRestore = atoi(argv[4]);
    mem.options.strictSpellCheck = 0;

    UkEngine engine;
    engine.setCtrlInfo(&mem);
    engine.setCheckKbCaseFunc([](int *shift, int *caps) { *shift = 0; *caps = 0; });
    engine.reset();

    const char *keys = argv[5];
    std::vector<unsigned int> display;  // committed codepoints, as the app sees them

    for (const char *p = keys; *p; ++p) {
        unsigned int ch = (unsigned char)*p;
        if (ch == '.') ch = ' ';  // word-break trigger

        int backs = 0;
        int bufChars = 1024;
        unsigned char buf[1024];
        UkOutputType outType;
        engine.process(ch, backs, buf, bufChars, outType);

        // Apply: delete `backs` trailing codepoints, then append the produced
        // bytes (or the passthrough char if the engine produced nothing).
        for (int k = 0; k < backs && !display.empty(); ++k)
            display.pop_back();
        if (bufChars > 0) {
            std::vector<unsigned int> add = decodeUtf8(buf, bufChars);
            for (unsigned int cp : add) display.push_back(cp);
        } else if (backs == 0) {
            // Engine consumed the key silently only when it composed; if it
            // neither backed up nor emitted, the raw char passes through.
            display.push_back(ch);
        }
    }

    std::string out = encodeUtf8(display);
    // Trim a single trailing space we injected for word-break tests.
    if (!out.empty() && out.back() == ' ') out.pop_back();
    printf("%s\n", out.c_str());
    return 0;
}
