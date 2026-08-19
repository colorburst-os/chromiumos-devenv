// Copyright 2018 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chromeos/ash/services/ime/public/cpp/rulebased/def/vi_telex.h"

#include <iterator>

namespace vi_telex {

const char* kId = "vi_telex";
bool kIs102 = false;
const char* kTransforms[] = {
    // NOTE(colorburst fork): five rules upstream's table never had. See
    // VIETNAMESE-ENGINE.md 1.5 for the measurements behind each.
    //
    // "uo" + w puts the horn on BOTH vowels, which is what a Telex typist
    // means: nguowfi -> nguoi with two horns -> "nguoi". Without this the
    // typist has to type the second w explicitly (nguwowfi).
    "[uU]\u001d?[oO]\u001d?[wW]",
    "\u01b0\u01a1",
    "[uU]\u001d?[oO]\u001d?[nN]\u001d?[gG]\u001d?[wW]",
    "\u01b0\u01a1ng",
    // Double-typing a modifier escapes it. That already worked for dd/aa/ee/oo
    // and for the tone keys, but not for the w family: uww gave "uu-horn"
    // instead of the literal "uw" the typist asked for.
    "\u01b0\u001d[wW]",
    "uw",
    "\u0103\u001d[wW]",
    "aw",
    "\u01a1\u001d[wW]",
    "ow",
    "d\u001d?d",
    "\u0111",
    "a\u001d?a",
    "\u00e2",
    "e\u001d?e",
    "\u00ea",
    "o\u001d?o",
    "\u00f4",
    "a\u001d?w",
    "\u0103",
    "o\u001d?w",
    "\u01a1",
    "u\u001d?w",
    "\u01b0",
    // NOTE(colorburst fork): upstream also mapped a bare "w" to u-horn. It is
    // removed: it is the rule that makes English unusable while Vietnamese is
    // selected (windows -> u-horn indow), and uw/aw/ow still give the horned
    // vowels. Mirrors the live JS table -- see VIETNAMESE-IME.md 9.
    "D\u001d?[Dd]",
    "\u0110",
    "A\u001d?[aA]",
    "\u00c2",
    "E\u001d?[eE]",
    "\u00ca",
    "O\u001d?[oO]",
    "\u00d4",
    "A\u001d?[wW]",
    "\u0102",
    "O\u001d?[wW]",
    "\u01a0",
    "U\u001d?[wW]",
    "\u01af",
    "\u0111\u001dd",
    "dd",
    "\u0110\u001dD",
    "DD",
    "\u00e2\u001da",
    "aa",
    "\u00ea\u001de",
    "ee",
    "\u00f4\u001do",
    "oo",
    "\u00c2\u001dA",
    "AA",
    "\u00ca\u001dE",
    "EE",
    "\u00d4\u001dO",
    "OO",
    "(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|["
    "bcdghklmnpqtvBCDGHKLMNPQTV]+)\u001d?[fF]",
    "\\1\u0300\\3",
    "(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|["
    "bcdghklmnpqtvBCDGHKLMNPQTV]+)\u001d?[sS]",
    "\\1\u0301\\3",
    "(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|["
    "bcdghklmnpqtvBCDGHKLMNPQTV]+)\u001d?[rR]",
    "\\1\u0309\\3",
    "(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|["
    "bcdghklmnpqtvBCDGHKLMNPQTV]+)\u001d?[xX]",
    "\\1\u0303\\3",
    "(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY])([aeiouyAEIOUY]?|["
    "bcdghklmnpqtvBCDGHKLMNPQTV]+)\u001d?[jJ]",
    "\\1\u0323\\3",
    "(["
    "\u0103\u00e2\u00ea\u00f4\u01a1\u01b0\u0102\u00c2\u00ca\u00d4\u01a0\u01af"
    "])\u001d?([a-zA-Z]*)[fF]",
    "\\1\u0300\\2",
    "(["
    "\u0103\u00e2\u00ea\u00f4\u01a1\u01b0\u0102\u00c2\u00ca\u00d4\u01a0\u01af"
    "])\u001d?([a-zA-Z]*)[sS]",
    "\\1\u0301\\2",
    "(["
    "\u0103\u00e2\u00ea\u00f4\u01a1\u01b0\u0102\u00c2\u00ca\u00d4\u01a0\u01af"
    "])\u001d?([a-zA-Z]*)[rR]",
    "\\1\u0309\\2",
    "(["
    "\u0103\u00e2\u00ea\u00f4\u01a1\u01b0\u0102\u00c2\u00ca\u00d4\u01a0\u01af"
    "])\u001d?([a-zA-Z]*)[xX]",
    "\\1\u0303\\2",
    "(["
    "\u0103\u00e2\u00ea\u00f4\u01a1\u01b0\u0102\u00c2\u00ca\u00d4\u01a0\u01af"
    "])\u001d?([a-zA-Z]*)[jJ]",
    "\\1\u0323\\2",
    "([\u0300\u0301\u0309\u0303\u0323])([a-yA-Y\u001d]*)([zZ])",
    "\\2",
    "(\u0300)([a-zA-Z\u001d]*)([fF])",
    "\\2\\3",
    "(\u0301)([a-zA-Z\u001d]*)([sS])",
    "\\2\\3",
    "(\u0309)([a-zA-Z\u001d]*)([rR])",
    "\\2\\3",
    "(\u0303)([a-zA-Z\u001d]*)([xX])",
    "\\2\\3",
    "(\u0323)([a-zA-Z\u001d]*)([jJ])",
    "\\2\\3",
    // Retyping a different tone REPLACES the one already there, rather than
    // stacking a second diacritic on the syllable: hoafs was "hoa" with both
    // grave and acute, and is now "hoa" with acute. Each rule matches the four
    // tones that are not the one being typed.
    "^(.*)([\u0301\u0309\u0303\u0323])([a-zA-Z\u001d]*)([fF])",
    "\\1\u0300\\3",
    "^(.*)([\u0300\u0309\u0303\u0323])([a-zA-Z\u001d]*)([sS])",
    "\\1\u0301\\3",
    "^(.*)([\u0300\u0301\u0303\u0323])([a-zA-Z\u001d]*)([rR])",
    "\\1\u0309\\3",
    "^(.*)([\u0300\u0301\u0309\u0323])([a-zA-Z\u001d]*)([xX])",
    "\\1\u0303\\3",
    "^(.*)([\u0300\u0301\u0309\u0303])([a-zA-Z\u001d]*)([jJ])",
    "\\1\u0323\\3",
    "(([qQ][uU]|[gG][iI])?[aeiouyAEIOUY]+)([\u0300\u0301\u0303\u0309\u0323])"
    "\u001d?([aeiouyAEIOUY])\u001d?([a-eg-ik-qtuvyA-EG-IK-QTUVY])",
    "\\1\\4\\3\\5",
    "([\u0300\u0301\u0303\u0309\u0323])(["
    "\u0103\u00e2\u00ea\u00f4\u01a1\u01b0\u0102\u00c2\u00ca\u00d4\u01a0\u01af"
    "])\u001d?([a-zA-Z])",
    "\\2\\1\\3"};
const unsigned int kTransformsLen = std::size(kTransforms);
const char* kHistoryPrune = nullptr;

}  // namespace vi_telex
