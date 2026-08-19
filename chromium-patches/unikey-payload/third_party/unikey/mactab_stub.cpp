/*
 * SPDX-License-Identifier: LGPL-2.0-or-later
 *
 * colorburst: no-op implementation of CMacroTable. Upstream mactab.cpp pulls in
 * the GPL-2.0 vnconv/charset conversion machinery to store macro text in the
 * legacy StdVnChar charset. The PoC disables macros (gõ tắt), so we provide an
 * empty table: lookup() never matches and the engine's macro branch is inert.
 * Productionizing gõ tắt means porting mactab.cpp with a UTF-8 backing store.
 * See README.chromium.
 */
#include "mactab.h"

void CMacroTable::init() { m_count = 0; }
void CMacroTable::resetContent() { m_count = 0; }

const StdVnChar *CMacroTable::lookup(StdVnChar * /*key*/) { return nullptr; }
const StdVnChar *CMacroTable::getKey(int /*idx*/) const { return nullptr; }
const StdVnChar *CMacroTable::getText(int /*idx*/) const { return nullptr; }
