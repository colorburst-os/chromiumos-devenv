/*
 * SPDX-License-Identifier: LGPL-2.0-or-later
 *
 * colorburst: clean-room UTF-8 output layer for ukengine. Replaces upstream's
 * GPL-2.0 charset.cpp / data.cpp / convert.cpp / byteio.cpp. The engine hands us
 * StdVnChar values (VnStdCharOffset + VnLexiName, or a raw keycode byte); we emit
 * them straight to UTF-8. See README.chromium.
 */
#include "charset.h"
#include <cctype>

namespace {

void putUtf8(StringBOStream &os, unsigned int cp) {
    if (cp < 0x80) {
        os.putB((unsigned char)cp);
    } else if (cp < 0x800) {
        os.putB((unsigned char)(0xC0 | (cp >> 6)));
        os.putB((unsigned char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        os.putB((unsigned char)(0xE0 | (cp >> 12)));
        os.putB((unsigned char)(0x80 | ((cp >> 6) & 0x3F)));
        os.putB((unsigned char)(0x80 | (cp & 0x3F)));
    } else {
        os.putB((unsigned char)(0xF0 | (cp >> 18)));
        os.putB((unsigned char)(0x80 | ((cp >> 12) & 0x3F)));
        os.putB((unsigned char)(0x80 | ((cp >> 6) & 0x3F)));
        os.putB((unsigned char)(0x80 | (cp & 0x3F)));
    }
}

}  // namespace

int VnCharset::putChar(StringBOStream &os, StdVnChar stdChar, int &outLen) {
    unsigned int cp;
    if (stdChar >= VnStdCharOffset) {
        int idx = (int)(stdChar - VnStdCharOffset);
        if (idx >= 0 && idx < UkVnLexiCount) {
            cp = UkVnLexiToUnicode[idx];
        } else {
            cp = 0xFFFD;  // "special western" slots past the alphabet: rare, and
                          // never reachable from ASCII Telex keystrokes.
        }
    } else {
        cp = (unsigned int)(stdChar & 0xFF);  // raw pass-through byte (Latin-1).
    }
    int before = os.getOutBytes();
    putUtf8(os, cp);
    outLen = os.getOutBytes() - before;
    return 1;
}

StdVnChar StdVnToLower(StdVnChar ch) {
    if (ch >= VnStdCharOffset) {
        int idx = (int)(ch - VnStdCharOffset);
        // upper symbols are at even offsets, lower at even+1.
        if (idx >= 0 && idx < UkVnLexiCount && (idx & 1) == 0)
            return ch + 1;
        return ch;
    }
    return (StdVnChar)std::tolower((int)ch);
}

StdVnChar StdVnToUpper(StdVnChar ch) {
    if (ch >= VnStdCharOffset) {
        int idx = (int)(ch - VnStdCharOffset);
        if (idx >= 0 && idx < UkVnLexiCount && (idx & 1) == 1)
            return ch - 1;
        return ch;
    }
    return (StdVnChar)std::toupper((int)ch);
}

// Macro path only (disabled in the PoC): keep the symbol so linking succeeds.
int VnConvert(int, int, UKBYTE *, UKBYTE *, int *inLen, int *maxOutLen) {
    if (inLen)
        *inLen = 0;
    if (maxOutLen)
        *maxOutLen = 0;
    return 0;
}

VnCharsetLib VnCharsetLibObj;

const unsigned int *const UnicodeTable = UkVnLexiToUnicode;
