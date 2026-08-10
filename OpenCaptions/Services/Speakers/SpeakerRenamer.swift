//
//  SpeakerRenamer.swift
//  OpenCaptions
//
//  The single write path for speaker renames on a SAVED session: applies each new
//  name to every line of that speaker and commits SwiftData.
//
//  Lifted out of `MacSessionDetailView+SpeakerEditing` so the summary pass's
//  automatic naming can reuse it without routing through a view. Its callers are the
//  detail view's two rename sheets (batch + single) and `SummaryViewModel`.
//  See docs/2026-07-29-macos-speaker-auto-naming.md.
//

import Foundation
import SwiftData

@MainActor
enum SpeakerRenamer {

    /// Persists `edits` (speaker id → new name) onto `session`.
    ///
    /// Ignores non-diarized ids (`<= 0`), blank names, and no-op renames, so a
    /// caller can hand over a whole map without pre-filtering it. Returns what
    /// actually changed — `[:]` when nothing did, which is a normal outcome, not a
    /// failure. Never throws: a save error is logged, matching the other
    /// background write paths.
    @discardableResult
    static func apply(
        _ edits: [Int: String],
        to session: TranscriptionSession,
        context: ModelContext
    ) -> [Int: String] {
        let sanitized = sanitized(edits)
        guard !sanitized.isEmpty else { return [:] }

        // Lines with the same id share a name, so a rename fans out across all of
        // them. Only ids whose name actually differs are written and synced.
        var changed: [Int: String] = [:]
        for line in session.lines {
            guard let newName = sanitized[line.speakerId], line.speakerName != newName else { continue }
            line.speakerName = newName
            changed[line.speakerId] = newName
        }
        guard !changed.isEmpty else { return [:] }

        // Refresh the cached list-row summary so a rename shows up immediately.
        session.speakerNamesSummary = TranscriptionSession.makeSpeakerNamesSummary(from: session.lines)

        do {
            try context.save()
        } catch {
            print("❌ Speaker rename: failed to save renamed speakers: \(error.localizedDescription)")
        }

        // Speaker names appear in the exported transcript's per-line labels and its
        // `**Speakers:**` header, so a rename has to rewrite the file too.
        SessionExportCoordinator.export(session, context: context)

        return changed
    }

    /// Trims the names and drops anything that must never reach a line: non-positive
    /// ids (not real speakers) and blank names (which would erase the "Speaker N"
    /// fallback the app and the web view both rely on). The rename sheets already
    /// enforce both, so this only really guards the automatic summary path.
    private static func sanitized(_ edits: [Int: String]) -> [Int: String] {
        var result: [Int: String] = [:]
        for (id, name) in edits where id > 0 {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[id] = trimmed
        }
        return result
    }
}
