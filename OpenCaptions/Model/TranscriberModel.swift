//
//  TranscriberModel.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 21/10/25.
//

import Foundation
import SwiftData

/// In-memory model for current transcription session
@Observable
class TranscriberModel {
    
    // MARK: - Properties
    
    /// Array of transcribed text lines
    var textLines: [String] = []
    
    /// Array of speaker IDs corresponding to each text line
    var speakers: [Int] = []
    
    /// Array of time ranges for each line
    var times: [TimeRange] = []
    
    /// Array of speaker names for each line
    var name: [String] = []

    /// Source-app bundle id for each line (nil = mic / own voice, or attribution
    /// off). Index-aligned with the other per-line arrays. See
    /// docs/2026-07-07-macos-source-app-attribution.md.
    var sourceApps: [String?] = []

    /// Stable monotonic IDs for each bubble (used by ForEach for efficient diffing)
    var ids: [Int] = []

    /// Next ID to assign to a new bubble
    private var nextBubbleId: Int = 0

    /// Bumped when background persistence completes, so the view knows
    /// SwiftData now has the flushed lines and sortedLines can be recomputed.
    var persistenceVersion: Int = 0

    /// Bumped on every `appendOrAdd`, including one that grows the LAST bubble in
    /// place. The live views' auto-scroll pins on this: the transcript now commits
    /// one token at a time, so the newest text often arrives without `ids.count` or
    /// `partialLine` changing, and pinning on those alone would leave it below the
    /// fold. See docs/2026-07-29-macos-live-line-building.md.
    var revision: Int = 0

    /// Number of lines that have been flushed to SwiftData
    var flushedLineCount: Int = 0

    /// Persistent ID of the in-progress session for mid-session flushing (nil until first flush).
    /// Stored as an ID rather than the object so it can be fetched from any ModelContext.
    var activeSessionID: PersistentIdentifier?

    /// Stable Firestore session UUID for the current recording, minted at `start()`.
    /// Used by `FirestoreSyncService` and copied onto the SwiftData session row
    /// when it's created at first flush. Nil if Share Session was off at session start.
    var cloudSessionId: String?

    /// The signed-in user's Firebase UID, set at `start()` and stamped onto the
    /// SwiftData session at save time so history is scoped per user. Nil only when
    /// somehow unauthenticated (the app gate normally prevents recording then).
    var ownerUserId: String?

    /// Earliest valid start time (ms) seen this session, across hot and flushed lines.
    private var minValidStartMs: Int?

    /// Latest valid end time (ms) seen this session, across hot and flushed lines.
    private var maxValidEndMs: Int?

    /// Session duration in ms derived from the tracked time bounds. O(1).
    var currentDurationMs: Int {
        guard let minMs = minValidStartMs, let maxMs = maxValidEndMs else { return 0 }
        return max(0, maxMs - minMs)
    }

    // MARK: - Methods

    /// Appends text to the last line if the speaker matches, otherwise adds a new line.
    /// - Parameters:
    ///   - text: The text to add or append
    ///   - speaker: The speaker ID
    ///   - forceNewLine: If true, always create a new line even for the same speaker
    ///   - time: Time range for this segment
    ///   - sourceApp: Bundle id of the app that produced this segment's audio, or
    ///     nil for mic / own voice. Only recorded on a NEW bubble — a same-speaker
    ///     merge keeps the bubble's original app (see the file-level attribution
    ///     caveat in docs/2026-07-07-macos-source-app-attribution.md).
    func appendOrAdd(text: String, speaker: Int, forceNewLine: Bool = false, time: TimeRange, sourceApp: String? = nil) {
        guard !text.isEmpty else { return }
        defer { revision += 1 }

        // Track session time bounds so duration is O(1) at flush/save time
        if time.start_ms >= 0 && time.end_ms >= 0 {
            minValidStartMs = min(minValidStartMs ?? time.start_ms, time.start_ms)
            maxValidEndMs = max(maxValidEndMs ?? time.end_ms, time.end_ms)
        }

        if forceNewLine || speakers.isEmpty || speakers.last != speaker {
            textLines.append(text)
            speakers.append(speaker)
            times.append(time)
            name.append("Speaker \(speaker)")
            sourceApps.append(sourceApp)
            ids.append(nextBubbleId)
            nextBubbleId += 1
        } else {
            // Safety check: ensure arrays are not empty before accessing
            guard !textLines.isEmpty, !times.isEmpty else {
                // Fallback: add as new line
                textLines.append(text)
                speakers.append(speaker)
                times.append(time)
                name.append("Speaker \(speaker)")
                sourceApps.append(sourceApp)
                ids.append(nextBubbleId)
                nextBubbleId += 1
                return
            }
            
            let lastIndex = textLines.count - 1
            textLines[lastIndex] += text
            times[lastIndex] = TimeRange(
                start_ms: times[lastIndex].start_ms,
                end_ms: time.end_ms
            )
        }
    }

    /// Updates the name for all instances of a specific speaker ID
    /// - Parameters:
    ///   - name: New name to assign
    ///   - id: Speaker ID to update
    func updateName(name: String, id: Int) {
        for i in speakers.indices {
            // Safety check: ensure name array is large enough
            if speakers[i] == id && i < self.name.count {
                self.name[i] = name
            }
        }
    }

    /// Clears all transcription data and resets flush state
    func clear() {
        textLines.removeAll()
        speakers.removeAll()
        times.removeAll()
        name.removeAll()
        sourceApps.removeAll()
        ids.removeAll()
        nextBubbleId = 0
        revision = 0
        flushedLineCount = 0
        activeSessionID = nil
        cloudSessionId = nil
        ownerUserId = nil
        minValidStartMs = nil
        maxValidEndMs = nil
    }
}
