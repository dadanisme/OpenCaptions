//
//  MacAIModelsSettingsView.swift
//  OpenCaptions
//
//  The Settings → AI Models pane: the Transcription Engine, Summary Model,
//  OpenRouter Model, and Chat Model pickers — split out of the General pane
//  into its own top-level tab as this section grew a 4th picker (#58). Previously a single `Section("AI Models")` inside
//  `MacSettingsView.generalPane`; see that file's own history for the prior
//  layout. See docs/2026-08-18-macos-openrouter-model-picker.md and
//  docs/2026-09-16-macos-session-chat.md.
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
    /// The two-way summary provider selection — OpenRouter (cloud) or Apple
    /// Foundation Models (on-device, macOS 26+). Independent of `selectedEngine`
    /// above: which model transcribed a session has no bearing on which model can
    /// summarize it.
    @AppStorage(LiveSessionStore.summaryProviderKindKey) private var summaryProvider: SummaryProviderKind = .openRouter
    /// Which OpenRouter model runs whichever feature is set to `.openRouter` —
    /// read by both `SummaryService+OpenRouter.requestBody` and
    /// `SessionChatService+OpenRouter.requestBody`. Hidden only when NEITHER the
    /// Summary Model nor the Chat Model is OpenRouter, since then nothing reads it.
    @AppStorage(LiveSessionStore.openRouterModelKindKey) private var openRouterModel: OpenRouterModelKind = .deepseekFlash
    /// The two-way Chat provider selection — OpenRouter (cloud) or Apple
    /// Foundation Models (on-device, macOS 26+). Independent of `summaryProvider`
    /// above: Chat resends the transcript AND the whole growing conversation on
    /// every turn, so it exhausts the on-device window far sooner than a one-shot
    /// summary does — a user may well want them on different providers. When set
    /// to `.openRouter` it uses the same `openRouterModel` picked above.
    @AppStorage(LiveSessionStore.chatProviderKindKey) private var chatProvider: ChatProviderKind = .openRouter

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
            } header: {
                SettingsInfoTip.label("Transcription", tip: "Which engine transcribes your live sessions. Re-transcribing a saved session or an imported file uses the same selection.")
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
                // Shown whenever EITHER feature routes through OpenRouter — the one
                // model choice serves both, so hiding it with the Summary Model
                // alone would strand a user who summarizes on-device but chats in
                // the cloud with no way to pick the model that answers them.
                if summaryProvider == .openRouter || chatProvider == .openRouter {
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
                        SettingsInfoTip.label("OpenRouter Model", tip: "Which model OpenRouter uses to generate summaries, name speakers, and answer Chat questions, grouped by provider. Every option supports the structured JSON output summaries rely on; where a provider ships more than one tier, Flagship/Standard/Lite/Budget trade quality for cost and speed — Budget picks the cheapest option that's still meaningfully capable.")
                    }
                }
            } header: {
                SettingsInfoTip.label("Summaries", tip: "Which model generates AI summaries and, from them, automatic speaker names. Independent of the Transcription Engine above — which model transcribed a session has no bearing on which model can summarize it.")
            }

            Section {
                LabeledContent {
                    Picker("", selection: $chatProvider) {
                        ForEach(ChatProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                } label: {
                    SettingsInfoTip.label("Chat Model", tip: chatProviderFootnote)
                }
                if let reason = chatProvider.unavailableReason {
                    // Nothing to download here — the OS manages Apple Intelligence's own
                    // model, so this is a plain explanation, not a Download control.
                    LabeledContent {
                        Text(reason).foregroundStyle(.secondary)
                    } label: {
                        Text("Apple Intelligence")
                    }
                }
            } header: {
                SettingsInfoTip.label("Chat", tip: "Which model answers questions in a session's Chat tab. Independent of the Summary Model above — every question resends the whole transcript plus the conversation so far, so Chat runs out of on-device context much sooner than a one-shot summary does.")
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

    /// Explanatory text shown in the Chat Model row's info tip.
    private var chatProviderFootnote: String {
        switch chatProvider {
        case .openRouter:
            return "Answer questions in the cloud with your OpenRouter key, using the OpenRouter Model selected above. Requires an internet connection."
        case .foundationModels:
            if let reason = chatProvider.unavailableReason {
                return "Answer questions entirely on this Mac using Apple Intelligence — no internet needed and your transcript never leaves your device. Currently unavailable: \(reason)"
            }
            return "Answer questions entirely on this Mac using Apple Intelligence — no internet needed and your transcript never leaves your device. Long sessions or long conversations may not fit; switch back to OpenRouter for those."
        }
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
