//
//  MacAIModelsSettingsView.swift
//  OpenCaptions
//
//  The Settings → AI Models pane: the Transcription Engine, Re-transcription
//  Engine, Summary Model, and OpenRouter Model pickers — split out of the
//  General pane into its own top-level tab as this section grew a 4th
//  picker (#58). Previously a single `Section("AI Models")` inside
//  `MacSettingsView.generalPane`; see that file's own history for the prior
//  layout. See docs/2026-08-18-macos-openrouter-model-picker.md.
//

import SwiftUI

struct MacAIModelsSettingsView: View {
    /// The transcription engine selection — Soniox (cloud), Nemotron or Parakeet
    /// (on-device FluidAudio), or Apple Speech (on-device, macOS 26+). Read at
    /// session start by `MacTranscriptionViewModel.start`. Selecting an on-device
    /// engine whose model isn't downloaded yet shows a Download control in place
    /// of the picker. `MacSettingsView` also declares its own `@AppStorage` onto
    /// this same key, just to compute its speaker-naming toggle's `isOffline`.
    @AppStorage(LiveSessionStore.transcriptionEngineKindKey) private var selectedEngine: MacTranscriptionEngineKind = .soniox
    /// Explicit override for the RE-TRANSCRIPTION (batch/post-session/import) engine,
    /// independent of `selectedEngine` above — empty means "follow it" (the default
    /// for every existing user). Only ever shown to the user on macOS 27+, where
    /// Core AI Parakeet (batch-only, can't run live) makes an override meaningful;
    /// see `LiveSessionStore.retranscriptionEngineKind`. Not `private`: read from
    /// `MacAIModelsSettingsView+Retranscription.swift`, which builds the row that
    /// binds it (kept in its own file per CLAUDE.md's line-budget convention).
    @AppStorage(LiveSessionStore.retranscriptionEngineOverrideKey) var retranscriptionOverrideRaw = ""
    /// The two-way summary provider selection — OpenRouter (cloud) or Apple
    /// Foundation Models (on-device, macOS 26+). Independent of `selectedEngine`
    /// above: which model transcribed a session has no bearing on which model can
    /// summarize it.
    @AppStorage(LiveSessionStore.summaryProviderKindKey) private var summaryProvider: SummaryProviderKind = .openRouter
    /// Which OpenRouter model summarizes a session when `summaryProvider` is
    /// `.openRouter` — read by `SummaryService+OpenRouter.requestBody`. Meaningless
    /// (and hidden) for `.foundationModels`, which has no OpenRouter transport.
    @AppStorage(LiveSessionStore.openRouterModelKindKey) private var openRouterModel: OpenRouterModelKind = .deepseekFlash

    /// Whether the SELECTED engine is usable right now — always true for cloud
    /// Soniox; for an on-device engine, whether its own model has finished
    /// downloading. Per-model, not "both models" — the picker only ever needs the
    /// one model the current selection points at.
    private var selectedEngineReady: Bool {
        !selectedEngine.isOnDevice || selectedEngine.modelManager?.status == .ready
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Picker("", selection: $selectedEngine) {
                        ForEach(MacTranscriptionEngineKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                } label: {
                    SettingsInfoTip.label("Transcription Engine", tip: transcriptionEngineFootnote)
                }
                if !selectedEngineReady, let manager = selectedEngine.modelManager {
                    // Selected on-device model isn't downloaded yet — offer the
                    // Download control (or progress) right below the picker rather
                    // than blocking the selection itself; the picker stays usable so
                    // switching back to Soniox (or another already-downloaded engine)
                    // needs no extra step.
                    LabeledContent {
                        MacOfflineDownloadControl(manager: manager)
                    } label: {
                        Text(manager.modelTitle)
                    }
                }
                retranscriptionEngineRow
            } header: {
                SettingsInfoTip.label("Transcription", tip: "Which engine transcribes your live sessions, and optionally a different one for re-transcribing saved sessions and imported files.")
            }

            Section {
                LabeledContent {
                    Picker("", selection: $summaryProvider) {
                        ForEach(SummaryProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                } label: {
                    SettingsInfoTip.label("Summary Model", tip: summaryProviderFootnote)
                }
                if let reason = summaryProvider.unavailableReason {
                    // Nothing to download here — the OS manages Apple Intelligence's own
                    // model, so this is a plain explanation, not a Download control.
                    LabeledContent {
                        Text(reason).foregroundStyle(.secondary)
                    } label: {
                        Text("Apple Intelligence")
                    }
                }
                if summaryProvider == .openRouter {
                    LabeledContent {
                        Picker("", selection: $openRouterModel) {
                            ForEach(OpenRouterModelKind.Provider.allCases) { provider in
                                Section(provider.displayName) {
                                    ForEach(provider.models) { kind in
                                        Text(kind.displayName).tag(kind)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                    } label: {
                        SettingsInfoTip.label("OpenRouter Model", tip: "Which model OpenRouter uses to generate summaries and name speakers, grouped by provider. Every option supports the structured JSON output this app relies on; where a provider ships more than one tier, Flagship/Standard/Lite/Budget trade quality for cost and speed — Budget picks the cheapest option that's still meaningfully capable.")
                    }
                }
            } header: {
                SettingsInfoTip.label("Summaries", tip: "Which model generates AI summaries and, from them, automatic speaker names. Independent of the Transcription Engine above — which model transcribed a session has no bearing on which model can summarize it.")
            }
        }
        .formStyle(.grouped)
    }

    /// Explanatory text shown in the Transcription Engine row's info tip.
    private var transcriptionEngineFootnote: String {
        guard selectedEngine.isOnDevice else {
            return "Transcribe in the cloud with speaker labels. Requires an internet connection."
        }
        guard selectedEngineReady else {
            let modelTitle = selectedEngine.modelManager?.modelTitle ?? selectedEngine.displayName
            return "Download the \(modelTitle) to enable it. It's a one-time download kept on this Mac."
        }
        return "Transcribe entirely on this Mac (English only) — no internet needed and your audio never leaves your device. Applies to your next session."
    }

    /// Explanatory text shown in the Summary Model row's info tip.
    private var summaryProviderFootnote: String {
        switch summaryProvider {
        case .openRouter:
            return "Summarize in the cloud with your OpenRouter key. Requires an internet connection. Independent of your Transcription Engine choice above."
        case .foundationModels:
            if let reason = summaryProvider.unavailableReason {
                return "Summarize entirely on this Mac using Apple Intelligence — no internet needed and your transcript never leaves your device. Currently unavailable: \(reason)"
            }
            return "Summarize entirely on this Mac using Apple Intelligence — no internet needed and your transcript never leaves your device. Very long sessions may be too long to fit; switch back to OpenRouter for those."
        }
    }
}

#Preview {
    MacAIModelsSettingsView()
        .frame(width: 480, height: 460)
}
