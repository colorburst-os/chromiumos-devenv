/*
 * SPDX-License-Identifier: LGPL-2.0-or-later
 *
 * colorburst: clean-room replacement for upstream keycons.h (which upstream
 * ships as GPL-2.0-or-later). This header carries only the interface constants,
 * enums and the plain-old-data option struct that the LGPL ukengine/inputproc/
 * mactab require. Names and values are dictated by the engine's API (functional
 * interface, not creative expression) and were rewritten from the public API
 * surface, not copied from the GPL source. See README.chromium.
 */
#ifndef __KEY_CONS_H
#define __KEY_CONS_H

// Macro-table sizing (gõ tắt). Kept for ABI of CMacroTable; macros are disabled
// in the colorburst PoC so these only size unused storage.
#define MAX_MACRO_KEY_LEN 16
#define MAX_MACRO_TEXT_LEN 1024
#define MAX_MACRO_ITEMS 1024
#define MAX_MACRO_LINE (MAX_MACRO_TEXT_LEN + MAX_MACRO_KEY_LEN)
#define MACRO_MEM_SIZE (1024 * 128)

#define CP_US_ANSI 1252

enum UkInputMethod {
    UkTelex,
    UkVni,
    UkViqr,
    UkMsVi,
    UkUsrIM,
    UkSimpleTelex,
    UkSimpleTelex2
};

struct UnikeyOptions {
    int freeMarking;
    int modernStyle;
    int macroEnabled;
    int useUnicodeClipboard;
    int alwaysMacro;
    int strictSpellCheck;
    int useIME;
    int spellCheckEnabled;
    int autoNonVnRestore;
};

typedef enum { UkCharOutput, UkKeyOutput } UkOutputType;

#endif
