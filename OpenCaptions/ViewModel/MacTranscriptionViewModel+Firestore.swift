//
//  MacTranscriptionViewModel+Firestore.swift
//  OpenCaptions
//
//  Firestore share-to-web bridging for the live macOS transcription flow.
//  Sharing is per-session and explicit: a recording starts unsynced and only
//  begins mirroring when the user taps Share (`shareLive()`), which mints a
//  cloud session and backfills whatever is already on screen. After that, the
//  line-commit and partial hooks below fire Firestore writes; every one is a
//  no-op until `startSession` sets `currentSessionRef`. There are no manual
//  messages or Live Activity here. See
//  docs/2026-07-06-macos-firestore-share.md.
//

import Foundation

extension MacTranscriptionViewModel {

    /// True once the user has tapped Share on this session.
    var isShared: Bool { finalLines.cloudSessionId != nil }

    // MARK: - Share

    /// Promotes the current in-progress recording to a shared (publicly
    /// viewable) session and starts mirroring it to Firestore. Idempotent:
    /// tapping Share twice returns the existing cloud id without re-uploading.
    /// Returns the cloud session id, or nil if sharing is off / signed out.
    @MainActor
    @discardableResult
    func shareLive() -> String? {
        if let existing = finalLines.cloudSessionId { return existing }

        // Backfill the in-memory transcript so a viewer joining via the link
        // doesn't see a half-empty transcript. Parallel arrays should match in
        // length, but skip anything ragged rather than crash on share.
        var backfill: [FirestoreSyncService.BackfillLine] = []
        backfill.reserveCapacity(finalLines.ids.count)
        for i in finalLines.ids.indices {
            guard i < finalLines.textLines.count,
                  i < finalLines.speakers.count,
                  i < finalLines.times.count else { continue }
            backfill.append(FirestoreSyncService.BackfillLine(
                text: finalLines.textLines[i],
                speakerId: finalLines.speakers[i],
                startMs: finalLines.times[i].start_ms,
                endMs: finalLines.times[i].end_ms,
                bubbleId: finalLines.ids[i]
            ))
        }

        let cloudId = FirestoreSyncService.shared.startSession(
            title: workingTitle,
            startedAt: sessionStartDate,
            speakers: speakerMapping,
            backfill: backfill
        )
        finalLines.cloudSessionId = cloudId

        // If we shared while paused, sync that state up immediately.
        if isPaused, cloudId != nil {
            FirestoreSyncService.shared.pauseSession()
        }
        return cloudId
    }

    // MARK: - Live-sync hooks (all no-op until a session is shared)

    /// Mirrors the just-committed bubble to Firestore. Reads the last bubble's
    /// *post-mutation* state because `appendOrAdd` may have grown the existing
    /// tail rather than created a new line.
    @MainActor
    func mirrorCommittedLine(isNewBubble: Bool) {
        guard let lastId = finalLines.ids.last,
              let lastTime = finalLines.times.last,
              let lastText = finalLines.textLines.last,
              let lastSpeaker = finalLines.speakers.last else { return }
        FirestoreSyncService.shared.appendOrUpdateLine(
            text: lastText,
            speakerId: lastSpeaker,
            startMs: lastTime.start_ms,
            endMs: lastTime.end_ms,
            bubbleId: lastId,
            isNewBubble: isNewBubble
        )
    }

    /// Mirrors the in-flight (accumulator + partial) preview to the session
    /// doc's `accumulator` field so the web client renders a typing preview
    /// without touching committed `lines/{id}` docs. The service throttles to
    /// 1 write/sec. Clears the field when there is nothing in flight so a stale
    /// preview doesn't linger between sentences.
    @MainActor
    func pushPartialToFirestore(partialText: String) {
        let inflight = accumulator.text + partialText
        guard !inflight.isEmpty else {
            FirestoreSyncService.shared.clearAccumulator()
            return
        }
        // Carry whichever speaker the accumulator currently belongs to; fall
        // back to the last committed speaker so the web can still bind the
        // preview to a bubble, else -1 (unknown).
        let speakerId = accumulator.speaker != -1
            ? accumulator.speaker
            : (finalLines.speakers.last ?? -1)
        // Best-effort time hints: fall back to the last committed end time when
        // the accumulator hasn't claimed bounds yet (startMs/endMs == 0).
        let lastEndMs = finalLines.times.last?.end_ms ?? 0
        let startMs = accumulator.startMs != 0 ? accumulator.startMs : lastEndMs
        let endMs = accumulator.endMs != 0 ? accumulator.endMs : lastEndMs

        FirestoreSyncService.shared.updateAccumulator(
            text: inflight,
            speakerId: speakerId,
            startMs: startMs,
            endMs: endMs
        )
    }
}
