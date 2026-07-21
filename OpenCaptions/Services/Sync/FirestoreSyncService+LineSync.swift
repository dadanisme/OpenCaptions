//
//  FirestoreSyncService+LineSync.swift
//  OpenCaptions
//
//  Line-commit and in-flight accumulator sync for FirestoreSyncService,
//  including the 1-write/sec accumulator throttle with trailing flush.
//

import Foundation
import FirebaseFirestore

extension FirestoreSyncService {

    // MARK: - Public API (line & accumulator sync)

    /// Commits a finalized sentence to a line document. **Only called for
    /// finalized text** — partial/in-flight text goes through
    /// `updateAccumulator(...)` instead and never touches the `lines`
    /// subcollection.
    ///
    /// The `accumulator` field is intentionally **not** touched here. The
    /// iOS UI does not reset its in-flight `partialLine` string on commit;
    /// instead the next `updatePartialLine` callback either overwrites it
    /// with the new partial or empties it. We mirror that on Firestore so
    /// the web client sees the same transition the iOS user does — no
    /// extra null-flicker between commit and the next partial frame.
    ///
    /// All lines render identically on iOS and on the web. There is no
    /// per-line status — the most recent bubble's `text` may still grow on
    /// the next sentence commit when the speaker hasn't changed, and the
    /// web simply re-renders.
    ///
    /// - Parameter isNewBubble: True if `appendOrAdd` just created a new line
    ///   (speaker change or `forceNewLine`). The caller detects this by
    ///   comparing `finalLines.ids.count` before vs. after the call. When
    ///   true we `createDoc` a new line; when false we patch the existing
    ///   doc's text/endMs.
    func appendOrUpdateLine(
        text: String,
        speakerId: Int,
        startMs: Int,
        endMs: Int,
        bubbleId: Int,
        isNewBubble: Bool
    ) {
        guard let session = currentSessionRef, let uid = currentUid() else { return }
        let lineId = formatLineId(bubbleId)

        if isNewBubble {
            createDoc(session.collection("lines").document(lineId), uid: uid, data: [
                F.text: text,
                F.speakerId: speakerId,
                F.startMs: startMs,
                F.endMs: endMs,
            ])
            // Best-effort lineCount bump so the web client can show a stable count.
            updateDoc(session, uid: uid, data: [F.lineCount: bubbleId + 1])
            return
        }

        // Same bubble — overwrite committed text with the latest sentence
        // boundary. No throttle: sentence commits are sparse (a few per
        // minute), unlike the partial stream.
        updateDoc(session.collection("lines").document(lineId), uid: uid, data: [
            F.text: text,
            F.endMs: endMs,
        ])
    }

    /// Pushes the in-flight (partial + sentence-accumulator) preview text
    /// to the session doc's `accumulator` field. Throttled at 1 write/sec
    /// with a trailing flush so the last keystroke always lands.
    ///
    /// The accumulator field is the **only** way in-flight text reaches
    /// Firestore — `lines/{lineId}` documents are written only with
    /// committed text via `appendOrUpdateLine(...)`.
    ///
    /// Callers should pass just the in-flight portion. The web client
    /// renders it as a standalone preview bubble below the lines list, not
    /// joined to any line — mirrors how iOS renders `partialLine` via
    /// `PartialSpeakerBubble`. Call `clearAccumulator()` when there is
    /// nothing pending.
    func updateAccumulator(text: String, speakerId: Int, startMs: Int, endMs: Int) {
        guard currentSessionRef != nil, currentUid() != nil else { return }
        pendingAccumulator = AccumulatorSnapshot(
            text: text,
            speakerId: speakerId,
            startMs: startMs,
            endMs: endMs
        )
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastAccumulatorWrite
        if elapsed >= Self.accumulatorMinInterval {
            flushAccumulator()
        } else {
            scheduleAccumulatorFlush(after: Self.accumulatorMinInterval - elapsed)
        }
    }

    /// Clears the in-flight `accumulator` field on the session doc. Safe to
    /// call when no session is active (no-op).
    func clearAccumulator() {
        guard let session = currentSessionRef, let uid = currentUid() else { return }
        pendingAccumulator = nil
        pendingAccumulatorFlush?.cancel()
        pendingAccumulatorFlush = nil
        updateDoc(session, uid: uid, data: [F.accumulator: NSNull()])
        lastAccumulatorWrite = CFAbsoluteTimeGetCurrent()
    }

    // MARK: - Accumulator throttle internals

    /// Writes the most recent accumulator snapshot to the session doc and
    /// resets throttle state. Called immediately when the throttle window
    /// has elapsed, or as a trailing flush via `DispatchWorkItem`.
    private func flushAccumulator() {
        guard let session = currentSessionRef,
              let uid = currentUid(),
              let snap = pendingAccumulator else { return }

        updateDoc(session, uid: uid, data: [
            F.accumulator: [
                F.text: snap.text,
                F.speakerId: snap.speakerId,
                F.startMs: snap.startMs,
                F.endMs: snap.endMs,
            ],
        ])
        lastAccumulatorWrite = CFAbsoluteTimeGetCurrent()
        pendingAccumulatorFlush = nil
    }

    private func scheduleAccumulatorFlush(after delay: TimeInterval) {
        pendingAccumulatorFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushAccumulator()
            }
        }
        pendingAccumulatorFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
