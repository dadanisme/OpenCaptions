//
//  MacAIModelsSettingsView+Retranscription.swift
//  OpenCaptions
//
//  The "Re-transcription Engine" Settings row — an override for the batch/
//  post-session/import engine, independent of the live Transcription Engine
//  picker in MacAIModelsSettingsView itself. Split out to keep that file under
//  its line budget, mirroring MacSessionDetailView+Retranscription.swift's split
//  of the same concern on the session-detail side. See #47 / #58 /
//  docs/2026-08-12-macos-coreai-plugin-skeleton.md. Renders as a bare row
//  (no Section of its own) so it can sit inside MacAIModelsSettingsView's
//  "Transcription" section, right below the Transcription Engine row.
//

import SwiftUI

extension MacAIModelsSettingsView {

    /// Only rendered on macOS 27+: below that, `RetranscriptionEngineKind
    /// .availableCases` never offers anything the live picker above can't
    /// already do, so an override control would be pure clutter for every user
    /// who can't reach a different outcome from it.
    @ViewBuilder
    var retranscriptionEngineRow: some View {
        if #available(macOS 27.0, *) {
            LabeledContent {
                Picker("", selection: retranscriptionOverrideBinding) {
                    Text("Same as Transcription Engine").tag(RetranscriptionEngineKind?.none)
                    ForEach(RetranscriptionEngineKind.availableCases) { kind in
                        Text(kind.displayName).tag(RetranscriptionEngineKind?.some(kind))
                    }
                }
                .labelsHidden()
            } label: {
                SettingsInfoTip.label("Re-transcription Engine", tip: retranscriptionEngineFootnote)
            }
        }
    }

    /// Bridges the empty-string-means-nil `retranscriptionOverrideRaw` to a proper
    /// `Optional` for the picker — `@AppStorage` has no direct support for an
    /// Optional `RawRepresentable`, so the raw string is the actual storage and this
    /// is just a view onto it.
    private var retranscriptionOverrideBinding: Binding<RetranscriptionEngineKind?> {
        Binding(
            get: { RetranscriptionEngineKind(rawValue: retranscriptionOverrideRaw) },
            set: { retranscriptionOverrideRaw = $0?.rawValue ?? "" }
        )
    }

    /// Explanatory text shown in the Re-transcription Engine row's info tip.
    private var retranscriptionEngineFootnote: String {
        "Chooses the engine for re-transcribing saved sessions and imported files — independent of the Transcription Engine above, which only covers live sessions. Defaults to following that selection; override it if you want a different engine for batch processing, such as Core AI Parakeet, which can only run in this batch mode."
    }
}
