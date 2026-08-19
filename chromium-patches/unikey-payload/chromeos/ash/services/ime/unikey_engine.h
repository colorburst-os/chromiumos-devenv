// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// colorburst PoC: a mojom::InputMethod backed by the vendored LGPL UniKey
// engine (//third_party/unikey), selected for the Vietnamese Telex layout in
// place of the stateless rule-based transliterator. See
// internal-knowledge/VIETNAMESE-IME-PERF.md.

#ifndef CHROMEOS_ASH_SERVICES_IME_UNIKEY_ENGINE_H_
#define CHROMEOS_ASH_SERVICES_IME_UNIKEY_ENGINE_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "chromeos/ash/services/ime/public/mojom/input_method.mojom.h"
#include "chromeos/ash/services/ime/public/mojom/input_method_host.mojom.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/pending_associated_receiver.h"
#include "mojo/public/cpp/bindings/pending_associated_remote.h"

// Forward-declared to keep the vendored engine's headers out of this one.
class UkEngine;
struct UkSharedMem;

namespace ash {
namespace ime {

class UnikeyEngine : public mojom::InputMethod {
 public:
  // Returns nullptr if `ime_spec` is not a Vietnamese layout this engine backs.
  // `settings` is applied immediately (the rule-based mojo path never delivers
  // OnFocus, so connect time is our only settings hook today).
  static std::unique_ptr<UnikeyEngine> Create(
      const std::string& ime_spec,
      mojo::PendingAssociatedReceiver<mojom::InputMethod> receiver,
      mojo::PendingAssociatedRemote<mojom::InputMethodHost> host,
      const mojom::InputMethodSettingsPtr& settings);

  // Whether `ime_spec` is one this engine handles (m17n:vi_telex today).
  static bool IsImeSupported(const std::string& ime_spec);

  UnikeyEngine(const UnikeyEngine&) = delete;
  UnikeyEngine& operator=(const UnikeyEngine&) = delete;
  ~UnikeyEngine() override;

  bool IsConnected();

  // mojom::InputMethod:
  void OnFocusDeprecated(mojom::InputFieldInfoPtr input_field_info,
                         mojom::InputMethodSettingsPtr settings) override {}
  void OnFocus(mojom::InputFieldInfoPtr input_field_info,
               mojom::InputMethodSettingsPtr settings,
               OnFocusCallback callback) override;
  void OnBlur() override;
  void OnSurroundingTextChanged(
      const std::string& text,
      uint32_t offset,
      mojom::SelectionRangePtr selection_range) override {}
  void OnCompositionCanceledBySystem() override;
  void ProcessKeyEvent(mojom::PhysicalKeyEventPtr event,
                       ProcessKeyEventCallback callback) override;
  void OnCandidateSelected(uint32_t selected_candidate_index) override {}
  void OnAssistiveWindowChanged(
      const ash::ime::AssistiveWindow& window) override {}
  void OnQuickSettingsUpdated(
      mojom::InputMethodQuickSettingsPtr quick_settings) override {}
  void IsReadyForTesting(IsReadyForTestingCallback callback) override;

 private:
  UnikeyEngine(const std::string& ime_spec,
               mojo::PendingAssociatedReceiver<mojom::InputMethod> receiver,
               mojo::PendingAssociatedRemote<mojom::InputMethodHost> host,
               bool modern_tone_placement);

  // Applies engine settings (currently just the modern/classic tone toggle).
  void ApplyOptions(bool modern_tone_placement);

  // Pushes the current composition buffer to the host as a preedit.
  void UpdateComposition();
  // Commits the current composition buffer and resets the engine (word end).
  void CommitAndReset();

  mojo::AssociatedReceiver<mojom::InputMethod> receiver_;
  mojo::AssociatedRemote<mojom::InputMethodHost> host_;

  std::unique_ptr<UkSharedMem> mem_;
  std::unique_ptr<UkEngine> engine_;

  // The word currently being composed, as Unicode codepoints (what the app
  // shows as preedit). Held uncommitted until a word boundary so the engine's
  // non-Vietnamese restore (D4) can rewrite it.
  std::vector<uint32_t> composition_;
};

}  // namespace ime
}  // namespace ash

#endif  // CHROMEOS_ASH_SERVICES_IME_UNIKEY_ENGINE_H_
