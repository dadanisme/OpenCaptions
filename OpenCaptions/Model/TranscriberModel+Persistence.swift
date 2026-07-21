//
//  TranscriberModel+Persistence.swift
//  unmute
//
//  Created by Wentao Guo on 21/10/25.
//

import Foundation
import SwiftData

// MARK: - Persistence

extension TranscriberModel {
    /// Extracts oldest lines from in-memory arrays for persistence.
    /// Returns the extracted data; caller persists it on a background context.
    @MainActor
    func extractOldLines() -> [(text: String, speakerId: Int, speakerName: String, startMs: Int, endMs: Int, sourceApp: String?)]? {
        let count = textLines.count
        guard count > TranscriptionConstants.flushThreshold else { return nil }

        let flushCount = TranscriptionConstants.flushBatchSize
        guard flushCount <= count else { return nil }

        // Extract data before removing
        var extracted: [(text: String, speakerId: Int, speakerName: String, startMs: Int, endMs: Int, sourceApp: String?)] = []
        for i in 0..<flushCount {
            extracted.append((
                text: textLines[i],
                speakerId: speakers[i],
                speakerName: name[i],
                startMs: times[i].start_ms,
                endMs: times[i].end_ms,
                sourceApp: i < sourceApps.count ? sourceApps[i] : nil
            ))
        }

        // Remove flushed lines from in-memory arrays
        textLines.removeFirst(flushCount)
        speakers.removeFirst(flushCount)
        times.removeFirst(flushCount)
        name.removeFirst(flushCount)
        sourceApps.removeFirst(flushCount)
        ids.removeFirst(flushCount)

        flushedLineCount += flushCount

        return extracted
    }

    /// Persists extracted lines to SwiftData on a background context.
    /// - Parameters:
    ///   - durationMs: Session duration computed on the main thread at extract time,
    ///     stored on the session so list cards never scan `lines`.
    func persistLines(
        _ lines: [(text: String, speakerId: Int, speakerName: String, startMs: Int, endMs: Int, sourceApp: String?)],
        to context: ModelContext,
        sessionID: PersistentIdentifier,
        durationMs: Int
    ) {
        guard let session = context.model(for: sessionID) as? TranscriptionSession else {
            print("❌ persistLines: could not resolve session from ID")
            return
        }
        for line in lines {
            let dbLine = TranscriptionLine(
                text: line.text,
                speakerId: line.speakerId,
                speakerName: line.speakerName,
                startMs: line.startMs,
                endMs: line.endMs,
                sourceAppBundleID: line.sourceApp
            )
            dbLine.session = session
            context.insert(dbLine)
        }
        session.durationMs = durationMs
        // Lines flush oldest-first, so the first batch carries the opening lines.
        if session.previewText == nil {
            session.previewText = TranscriptionSession.makePreviewText(from: lines.prefix(5).map(\.text))
        }
        try? context.save()
    }

    /// Saves the current session to SwiftData asynchronously.
    /// Reuses an existing session (created during mid-session flushes) if present.
    /// - Parameters:
    ///   - modelContext: SwiftData model context
    ///   - title: Title for the session
    ///   - audioFileName: Filename of the recorded audio to reference, or nil.
    /// - Returns: The persistent identifier of the saved session
    @MainActor
    func saveSession(
        to modelContext: ModelContext,
        title: String = "",
        audioFileName: String? = nil
    ) async -> PersistentIdentifier {
        let session: TranscriptionSession

        if let existingID = activeSessionID,
           let existing = modelContext.model(for: existingID) as? TranscriptionSession {
            // Only overwrite the title when a real one is supplied. An empty title
            // here would blank the default "Session <date>" that `init` already set
            // when this row was created during a mid-session flush.
            if !title.isEmpty {
                existing.sessionTitle = title
            }
            // Mid-session row may have been created before sync started; backfill if needed.
            if existing.cloudSessionId == nil {
                existing.cloudSessionId = cloudSessionId
            }
            session = existing
        } else {
            session = TranscriptionSession(
                sessionDate: Date(),
                sessionTitle: title,
                cloudSessionId: cloudSessionId,
                userId: ownerUserId // scope to the signed-in user (set at start())
            )
            modelContext.insert(session)
        }

        // Reference the recorded audio (nil when recording was disabled/failed).
        if let audioFileName { session.audioFileName = audioFileName }

        // Save remaining hot lines
        for i in textLines.indices {
            let line = TranscriptionLine(
                text: textLines[i],
                speakerId: speakers[i],
                speakerName: name[i],
                startMs: times[i].start_ms,
                endMs: times[i].end_ms,
                sourceAppBundleID: i < sourceApps.count ? sourceApps[i] : nil
            )
            line.session = session
            modelContext.insert(line)
        }

        // Final derived-field update: duration covers all lines (flushed + hot);
        // preview is only set here for short sessions that never flushed.
        session.durationMs = currentDurationMs
        if session.previewText == nil {
            session.previewText = TranscriptionSession.makePreviewText(from: Array(textLines.prefix(5)))
        }

        do {
            try modelContext.save()
        } catch {
            print("❌ Save Session: Failed to save session: \(error.localizedDescription)")
        }

        activeSessionID = nil
        return session.persistentModelID
    }
}
