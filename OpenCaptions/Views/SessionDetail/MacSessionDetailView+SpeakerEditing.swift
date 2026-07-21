//
//  MacSessionDetailView+SpeakerEditing.swift
//  OpenCaptions
//
//  Speaker-rename support for a SAVED session's detail view: derives the
//  session's distinct diarized speakers for the edit sheet, then persists the
//  new names onto every matching line in SwiftData and mirrors the change to
//  the shared Firestore doc (when the session was shared). Split from
//  MacSessionDetailView to stay under the line limit. See issue #246.
//

import SwiftData
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
        var nameById: [Int: String] = [:]
        for line in session.lines where line.speakerId > 0 {
            if nameById[line.speakerId] == nil {
                nameById[line.speakerId] = line.speakerName
            }
        }
        return nameById.keys.sorted().map { id in
            MacEditSpeakersSheet.Speaker(
                id: id,
                originalName: nameById[id] ?? "Speaker \(id)",
                color: SpeakerPalette.color(for: id)
            )
        }
    }

    /// Persists renamed speakers: writes the new name onto every line of each
    /// changed speaker id, saves SwiftData, then mirrors the changes to the
    /// shared Firestore doc when this session was shared. `edits` is id → new
    /// (already-trimmed) name for every speaker; only ids whose name actually
    /// changed are written and synced.
    func saveSpeakerNames(_ edits: [Int: String]) {
        var changed: [Int: String] = [:]
        for line in session.lines {
            guard let newName = edits[line.speakerId], line.speakerName != newName else { continue }
            line.speakerName = newName
            changed[line.speakerId] = newName
        }
        guard !changed.isEmpty else { return }

        do {
            try modelContext.save()
        } catch {
            print("❌ Edit Speakers: failed to save renamed speakers: \(error.localizedDescription)")
        }

        // Mirror to the shared web transcript's `speakers` map when this session
        // was shared (no-op otherwise, or when sessionSharing is off / signed out).
        if let cloudId = session.cloudSessionId {
            FirestoreSyncService.shared.updateSpeakerNames(cloudSessionId: cloudId, names: changed)
        }
    }
}
