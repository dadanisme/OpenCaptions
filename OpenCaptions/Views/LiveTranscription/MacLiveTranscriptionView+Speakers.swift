//
//  MacLiveTranscriptionView+Speakers.swift
//  OgmoMac
//
//  Speaker-display + rename helpers for the live recording screen, split out of
//  MacLiveTranscriptionView to keep it under the per-file line limit (same pattern
//  as +AudioSource / +Sharing / +Billing). Methods are internal (not private) so
//  the bubble builder in the main file can call them across the extension.
//

import SwiftUI

extension MacLiveTranscriptionView {

    // MARK: - Rename

    /// Only diarized speakers (positive IDs) are renameable; the `-1`/`0`
    /// sentinels ("unknown"/pre-diarization) are not.
    func canRename(_ speaker: Int) -> Bool { speaker > 0 }

    func speaker(at index: Int) -> Int {
        index < viewModel.finalLines.speakers.count ? viewModel.finalLines.speakers[index] : -1
    }

    /// The source-app bundle id for a line, or nil (mic / own voice / attribution off).
    func sourceApp(at index: Int) -> String? {
        index < viewModel.finalLines.sourceApps.count ? viewModel.finalLines.sourceApps[index] : nil
    }

    /// Opens the rename sheet for the speaker of the tapped bubble, carrying their
    /// current name so the sheet's field prefills. The rename itself is applied in
    /// the sheet's commit callback via `viewModel.rename` (in-memory; the view model
    /// re-applies it to later lines and persists it on save).
    func beginRename(at index: Int) {
        let id = speaker(at: index)
        guard canRename(id) else { return }
        renameTarget = RenameTarget(speakerID: id, currentName: speakerName(at: index))
    }

    // MARK: - Speaker display

    func speakerName(at index: Int) -> String {
        index < viewModel.finalLines.name.count ? viewModel.finalLines.name[index] : "Speaker"
    }

    func speakerColor(at index: Int) -> Color {
        guard index < viewModel.finalLines.speakers.count else { return .accentColor }
        return SpeakerPalette.color(for: viewModel.finalLines.speakers[index])
    }
}

// MARK: - Rename target

/// Identifies the speaker being renamed for the `.sheet(item:)` presentation.
/// Carrying the current name here (captured at tap time) lets the sheet seed its
/// field deterministically.
struct RenameTarget: Identifiable {
    let speakerID: Int
    let currentName: String
    var id: Int { speakerID }
}
