//
//  MacSessionDetailView+SpeakerEditing.swift
//  OpenCaptions
//
//  Speaker-rename support for a SAVED session's detail view: derives the
//  session's distinct diarized speakers for the edit sheet. Split from
//  MacSessionDetailView to stay under the line limit.
//
//  The persistence itself lives in `SpeakerRenamer` (Services/Speakers), not here,
//  so the summary pass's automatic naming can reuse the same write path without
//  going through a view.
//

import SwiftUI

/// Identifies the speaker being renamed from a transcript bubble's right-click
/// menu, carrying the current name so `MacRenameSpeakerSheet`'s field prefills
/// deterministically. Drives the detail view's `.sheet(item:)`.
struct SpeakerRenameTarget: Identifiable {
    let speakerID: Int
    let currentName: String
    var id: Int { speakerID }
}

extension MacSessionDetailView {

    /// The session's distinct **diarized** speakers (positive ids only), sorted
    /// by id, each with the current name and its stable palette color. Empty for
    /// a non-diarized session (every line's id is -1/0) — the "Edit Speakers"
    /// action is disabled in that case. Lines with the same id share a name
    /// (renames apply to all of them), so the first occurrence is authoritative.
    var editableSpeakers: [MacEditSpeakersSheet.Speaker] {
        SpeakerLabel.distinctSpeakers(from: session.lines)
            .map { speaker in
                MacEditSpeakersSheet.Speaker(
                    id: speaker.id,
                    originalName: speaker.name,
                    color: SpeakerPalette.color(for: speaker.id)
                )
            }
            .sorted { $0.id < $1.id }
    }
}
