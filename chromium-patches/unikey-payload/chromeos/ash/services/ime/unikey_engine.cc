// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chromeos/ash/services/ime/unikey_engine.h"

#include <cstring>

#include "base/memory/ptr_util.h"
#include "base/strings/utf_string_conversions.h"

// Vendored LGPL UniKey engine (//third_party/unikey).
#include "third_party/unikey/charset.h"
#include "third_party/unikey/inputproc.h"
#include "third_party/unikey/keycons.h"
#include "third_party/unikey/mactab.h"
#include "third_party/unikey/ukengine.h"

namespace ash {
namespace ime {

namespace {

constexpr char kTelexSpec[] = "m17n:vi_telex";

// Maps a physical key (US QWERTY) to its base and shifted ASCII characters.
// Returns 0 for keys the engine has no interest in. Only the subset Telex
// needs (letters, digits, space, common punctuation) is populated.
struct KeyChars {
  char base;
  char shifted;
};

KeyChars UsLayoutChar(mojom::DomCode code) {
  using DomCode = mojom::DomCode;
  if (code >= DomCode::kKeyA && code <= DomCode::kKeyZ) {
    char c = 'a' + (static_cast<int>(code) - static_cast<int>(DomCode::kKeyA));
    return {c, static_cast<char>(c - 'a' + 'A')};
  }
  switch (code) {
    case DomCode::kDigit0: return {'0', ')'};
    case DomCode::kDigit1: return {'1', '!'};
    case DomCode::kDigit2: return {'2', '@'};
    case DomCode::kDigit3: return {'3', '#'};
    case DomCode::kDigit4: return {'4', '$'};
    case DomCode::kDigit5: return {'5', '%'};
    case DomCode::kDigit6: return {'6', '^'};
    case DomCode::kDigit7: return {'7', '&'};
    case DomCode::kDigit8: return {'8', '*'};
    case DomCode::kDigit9: return {'9', '('};
    case DomCode::kSpace: return {' ', ' '};
    case DomCode::kMinus: return {'-', '_'};
    case DomCode::kEqual: return {'=', '+'};
    case DomCode::kBracketLeft: return {'[', '{'};
    case DomCode::kBracketRight: return {']', '}'};
    case DomCode::kBackslash: return {'\\', '|'};
    case DomCode::kSemicolon: return {';', ':'};
    case DomCode::kQuote: return {'\'', '"'};
    case DomCode::kBackquote: return {'`', '~'};
    case DomCode::kComma: return {',', '<'};
    case DomCode::kPeriod: return {'.', '>'};
    case DomCode::kSlash: return {'/', '?'};
    default: return {0, 0};
  }
}

// A word boundary commits the composition. UkEngine treats these as word-break
// events internally too (see UkCharType::ukcWordBreak); we mirror that here so
// the preedit is flushed and the engine's per-word state can restart.
bool IsWordBreakChar(char c) {
  return c == ' ' || (c != 0 && !((c >= 'a' && c <= 'z') ||
                                  (c >= 'A' && c <= 'Z') ||
                                  (c >= '0' && c <= '9')));
}

std::u16string CodepointsToU16(const std::vector<uint32_t>& cps) {
  std::u16string out;
  for (uint32_t cp : cps) {
    if (cp <= 0xFFFF) {
      out.push_back(static_cast<char16_t>(cp));
    } else {
      cp -= 0x10000;
      out.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
      out.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
    }
  }
  return out;
}

// Decodes a UTF-8 byte run (as produced by the engine's UTF-8 emitter) into
// codepoints.
void AppendUtf8(const unsigned char* b, int n, std::vector<uint32_t>* out) {
  int i = 0;
  while (i < n) {
    unsigned char c = b[i];
    uint32_t cp;
    int len;
    if (c < 0x80) { cp = c; len = 1; }
    else if ((c >> 5) == 0x6) { cp = c & 0x1F; len = 2; }
    else if ((c >> 4) == 0xE) { cp = c & 0x0F; len = 3; }
    else { cp = c & 0x07; len = 4; }
    for (int k = 1; k < len && i + k < n; ++k)
      cp = (cp << 6) | (b[i + k] & 0x3F);
    out->push_back(cp);
    i += len;
  }
}

}  // namespace

// static
bool UnikeyEngine::IsImeSupported(const std::string& ime_spec) {
  return ime_spec == kTelexSpec;
}

// static
std::unique_ptr<UnikeyEngine> UnikeyEngine::Create(
    const std::string& ime_spec,
    mojo::PendingAssociatedReceiver<mojom::InputMethod> receiver,
    mojo::PendingAssociatedRemote<mojom::InputMethodHost> host,
    const mojom::InputMethodSettingsPtr& settings) {
  if (!IsImeSupported(ime_spec))
    return nullptr;
  bool modern = false;
  if (settings && settings->is_vietnamese_telex_settings()) {
    modern = settings->get_vietnamese_telex_settings()
                 ->new_style_tone_mark_placement;
  }
  return base::WrapUnique(new UnikeyEngine(ime_spec, std::move(receiver),
                                           std::move(host), modern));
}

UnikeyEngine::UnikeyEngine(
    const std::string& ime_spec,
    mojo::PendingAssociatedReceiver<mojom::InputMethod> receiver,
    mojo::PendingAssociatedRemote<mojom::InputMethodHost> host,
    bool modern_tone_placement)
    : receiver_(this, std::move(receiver)),
      host_(std::move(host)),
      mem_(std::make_unique<UkSharedMem>()),
      engine_(std::make_unique<UkEngine>()) {
  SetupUnikeyEngine();
  std::memset(mem_.get(), 0, sizeof(UkSharedMem));
  mem_->input.init();
  mem_->macStore.init();
  mem_->vietKey = true;
  mem_->usrKeyMapLoaded = false;
  mem_->charsetId = CONV_CHARSET_XUTF8;
  mem_->input.setIM(UkTelex);
  ApplyOptions(modern_tone_placement);

  engine_->setCtrlInfo(mem_.get());
  engine_->setCheckKbCaseFunc(
      [](int* shift, int* caps) { *shift = 0; *caps = 0; });
  engine_->reset();

  receiver_.set_disconnect_handler(
      base::BindOnce(&mojo::AssociatedReceiver<mojom::InputMethod>::reset,
                     base::Unretained(&receiver_)));
}

UnikeyEngine::~UnikeyEngine() = default;

void UnikeyEngine::ApplyOptions(bool modern_tone_placement) {
  mem_->options.freeMarking = 1;
  mem_->options.modernStyle = modern_tone_placement ? 1 : 0;
  mem_->options.macroEnabled = 0;
  mem_->options.spellCheckEnabled = 1;   // needed for the D4 restore logic
  mem_->options.autoNonVnRestore = 1;    // D4: restore non-Vietnamese words
  mem_->options.strictSpellCheck = 0;
  mem_->options.useUnicodeClipboard = 0;
  mem_->options.alwaysMacro = 0;
}

bool UnikeyEngine::IsConnected() {
  return receiver_.is_bound();
}

void UnikeyEngine::OnFocus(mojom::InputFieldInfoPtr input_field_info,
                           mojom::InputMethodSettingsPtr settings,
                           OnFocusCallback callback) {
  // Unlike RuleBasedEngine (which discards settings and reports failure), read
  // the Telex tone-placement toggle so D1 is actually configurable.
  bool modern = false;
  if (settings && settings->is_vietnamese_telex_settings()) {
    modern = settings->get_vietnamese_telex_settings()
                 ->new_style_tone_mark_placement;
  }
  ApplyOptions(modern);
  engine_->reset();
  composition_.clear();
  std::move(callback).Run(/*success=*/true,
                          /*metadata=*/mojom::InputMethodMetadataPtr(nullptr));
}

void UnikeyEngine::OnBlur() {
  CommitAndReset();
}

void UnikeyEngine::OnCompositionCanceledBySystem() {
  engine_->reset();
  composition_.clear();
}

void UnikeyEngine::UpdateComposition() {
  std::u16string text = CodepointsToU16(composition_);
  std::vector<mojom::CompositionSpanPtr> spans;
  spans.push_back(mojom::CompositionSpan::New(
      0, text.length(), mojom::CompositionSpanStyle::kNone));
  const int cursor = text.length();
  host_->SetComposition(std::move(text), std::move(spans), cursor);
}

void UnikeyEngine::CommitAndReset() {
  if (!composition_.empty()) {
    host_->CommitText(CodepointsToU16(composition_),
                      mojom::CommitTextCursorBehavior::kMoveCursorAfterText);
  }
  composition_.clear();
  engine_->reset();
}

void UnikeyEngine::ProcessKeyEvent(mojom::PhysicalKeyEventPtr event,
                                   ProcessKeyEventCallback callback) {
  // Only key-down; let modifiers/shortcuts through untouched.
  if (event->type != mojom::KeyEventType::kKeyDown ||
      event->modifier_state->control || event->modifier_state->alt) {
    std::move(callback).Run(mojom::KeyEventResult::kNeedsHandlingBySystem);
    return;
  }

  if (event->code == mojom::DomCode::kBackspace) {
    if (composition_.empty()) {
      std::move(callback).Run(mojom::KeyEventResult::kNeedsHandlingBySystem);
      return;
    }
    int backs = 0, out_size = 1024;
    unsigned char buf[1024];
    UkOutputType out_type;
    engine_->processBackspace(backs, buf, out_size, out_type);
    for (int k = 0; k < backs && !composition_.empty(); ++k)
      composition_.pop_back();
    if (out_size > 0)
      AppendUtf8(buf, out_size, &composition_);
    else if (backs == 0 && !composition_.empty())
      composition_.pop_back();  // plain delete of one preedit char
    UpdateComposition();
    std::move(callback).Run(mojom::KeyEventResult::kConsumedByIme);
    return;
  }

  KeyChars kc = UsLayoutChar(event->code);
  if (kc.base == 0) {
    // A key we don't map (arrows, function keys): flush and pass through.
    CommitAndReset();
    std::move(callback).Run(mojom::KeyEventResult::kNeedsHandlingBySystem);
    return;
  }

  const bool shift = event->modifier_state->shift;
  const bool caps = event->modifier_state->caps_lock;
  char ch;
  if (kc.base >= 'a' && kc.base <= 'z') {
    // For letters, the effective case is shift XOR caps-lock.
    ch = (shift != caps) ? kc.shifted : kc.base;
  } else {
    // Symbols/digits: only shift matters; caps-lock is ignored.
    ch = shift ? kc.shifted : kc.base;
  }

  int backs = 0, out_size = 1024;
  unsigned char buf[1024];
  UkOutputType out_type;
  int ret = engine_->process(static_cast<unsigned char>(ch), backs, buf,
                             out_size, out_type);

  for (int k = 0; k < backs && !composition_.empty(); ++k)
    composition_.pop_back();
  if (out_size > 0) {
    AppendUtf8(buf, out_size, &composition_);
  } else if (ret == 0) {
    // Passthrough: the engine did not touch the buffer; insert the raw char.
    composition_.push_back(static_cast<unsigned char>(ch));
  }

  if (IsWordBreakChar(ch)) {
    CommitAndReset();
  } else {
    UpdateComposition();
  }
  std::move(callback).Run(mojom::KeyEventResult::kConsumedByIme);
}

void UnikeyEngine::IsReadyForTesting(IsReadyForTestingCallback callback) {
  std::move(callback).Run(true);
}

}  // namespace ime
}  // namespace ash
