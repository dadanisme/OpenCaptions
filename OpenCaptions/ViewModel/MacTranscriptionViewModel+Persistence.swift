//
//  MacTranscriptionViewModel+Persistence.swift
//  OpenCaptions
//
//  The single funnel every committed line goes through: in-memory model →
//  Firestore mirror → debounced SwiftData flush (creating the session row on the
//  first flush so mid-session lines have a home).
//
//  Relocated here when the token accumulator was removed; the grouping decisions that
//  used to sit above it now live in `MacTranscriptionViewModel+Lines` / `LiveLineCursor`,
//  which is this funnel's only caller — including for the tail `stop()` commits, so even
//  that goes through the same placement path.
//

import Foundation
import SwiftData

extension MacTranscriptionViewModel {

    /// Appends a committed line to the in-memory model (speaker-grouped) and
    /// applies any speaker rename. Debounced flush to SwiftData for long sessions.
    @MainActor
    func saveTranscriptionLine(
        text: String, speaker: Int, forceNewLine: Bool, start: Int, end: Int, sourceApp: String?
    ) {
        let sliceTime = TimeRange(start_ms: start, end_ms: end)
        let prevBubbleCount = finalLines.ids.count
        finalLines.appendOrAdd(
            text: text, speaker: speaker, forceNewLine: forceNewLine,
            time: sliceTime, sourceApp: sourceApp
        )
        let isNewBubble = finalLines.ids.count > prevBubbleCount

        if let mappedName = speakerMapping[speaker] {
            finalLines.updateName(name: mappedName, id: speaker)
        }

        // Mirror the committed bubble to Firestore (no-op until shared).
        mirrorCommittedLine(isNewBubble: isNewBubble)

        guard finalLines.textLines.count > TranscriptionConstants.flushThreshold,
              flushTask == nil,
              let container = modelContainer else { return }

        // Create the session on first flush so mid-session lines have a home.
        if finalLines.activeSessionID == nil {
            let session = TranscriptionSession(
                sessionDate: Date(),
                sessionTitle: "",
                cloudSessionId: finalLines.cloudSessionId,
                userId: finalLines.ownerUserId // scope to the signed-in user (set at start())
            )
            let mainContext = ModelContext(container)
            mainContext.insert(session)
            try? mainContext.save()
            finalLines.activeSessionID = session.persistentModelID
        }

        if let extracted = finalLines.extractOldLines(),
           let sessionID = finalLines.activeSessionID {
            let model = finalLines
            let durationMs = finalLines.currentDurationMs
            flushTask = Task.detached {
                let bgContext = ModelContext(container)
                model.persistLines(extracted, to: bgContext, sessionID: sessionID, durationMs: durationMs)
                await MainActor.run { [weak self] in
                    self?.flushTask = nil
                    self?.finalLines.persistenceVersion += 1
                }
            }
        }
    }
}
