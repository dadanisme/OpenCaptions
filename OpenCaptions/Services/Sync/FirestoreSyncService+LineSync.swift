//
//  FirestoreSyncService+LineSync.swift
//  OpenCaptions
//
//  Line-commit and in-flight preview sync for FirestoreSyncService, including the
//  two 1-write/sec throttles (the open line document, and the session doc's
//  `accumulator` preview field) with their trailing flushes.
//

import Foundation
import FirebaseFirestore

extension FirestoreSyncService {

    // MARK: - Public API (line & preview sync)

    /// Commits finalized text to a line document. **Only called for finalized
    /// text** — partial/in-flight text goes through `updateAccumulator(...)`
    /// instead and never touches the `lines` subcollection.
    ///
    /// The `accumulator` field is intentionally **not** touched here. The
    /// live UI does not reset its in-flight `partialLine` string on commit;
    /// instead the next `updatePartialLine` callback either overwrites it
    /// with the new partial or empties it. We mirror that on Firestore so
    /// the web client sees the same transition — no
    /// extra null-flicker between commit and the next partial frame.
    ///
    /// All lines render identically on the web. There is no per-line status — the
    /// most recent bubble's `text` keeps growing as tokens are committed when the
    /// speaker hasn't changed, and the web simply re-renders.
    ///
    /// - Parameter isNewBubble: True if `appendOrAdd` just created a new line
    ///   (speaker change or `forceNewLine`). The caller detects this by
    ///   comparing `finalLines.ids.count` before vs. after the call. When
    ///   true we `createDoc` a new line; when false we coalesce the existing
    ///   doc's text/endMs at `lineUpdateMinInterval`.
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
            // Land the previous bubble's coalesced tail before moving on — it can
            // never grow again, and its snapshot names its own document.
            flushPendingLineUpdate()
            createDoc(session.collection("lines").document(lineId), uid: uid, data: [
                F.text: text,
                F.speakerId: speakerId,
                F.startMs: startMs,
                F.endMs: endMs,
            ])
            lastLineUpdateWrite = CFAbsoluteTimeGetCurrent()
            // Best-effort lineCount bump so the web client can show a stable count.
            updateDoc(session, uid: uid, data: [F.lineCount: bubbleId + 1])
            return
        }

        // Same bubble — the live path commits one token at a time, so coalesce and
        // send at most one write per second (trailing flush keeps the last words).
        pendingLineUpdate = LineUpdateSnapshot(lineId: lineId, text: text, endMs: endMs)
        let elapsed = CFAbsoluteTimeGetCurrent() - lastLineUpdateWrite
        if elapsed >= Self.lineUpdateMinInterval {
            flushPendingLineUpdate()
        } else {
            scheduleLineUpdateFlush(after: Self.lineUpdateMinInterval - elapsed)
        }
    }

    // MARK: - Open-line throttle internals

    /// Writes the most recent open-line snapshot and resets throttle state. Safe to
    /// call with nothing pending (no-op). Internal so pause/end can force it.
    func flushPendingLineUpdate() {
        pendingLineUpdateFlush?.cancel()
        pendingLineUpdateFlush = nil
        guard let session = currentSessionRef,
              let uid = currentUid(),
              let snap = pendingLineUpdate else { return }
        pendingLineUpdate = nil

        updateDoc(session.collection("lines").document(snap.lineId), uid: uid, data: [
            F.text: snap.text,
            F.endMs: snap.endMs,
        ])
        lastLineUpdateWrite = CFAbsoluteTimeGetCurrent()
    }

    private func scheduleLineUpdateFlush(after delay: TimeInterval) {
        pendingLineUpdateFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushPendingLineUpdate()
            }
        }
        pendingLineUpdateFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pushes the in-flight preview text (the engine's un-finalized partial)
    /// to the session doc's `accumulator` field. Throttled at 1 write/sec
    /// with a trailing flush so the last keystroke always lands.
    ///
    /// The accumulator field is the **only** way in-flight text reaches
    /// Firestore — `lines/{lineId}` documents are written only with
    /// committed text via `appendOrUpdateLine(...)`.
    ///
    /// Callers should pass just the in-flight portion. The web client
    /// renders it as a standalone preview bubble below the lines list, not
    /// joined to any line. Call `clearAccumulator()` when there is
    /// nothing pending.
    func updateAccumulator(text: String, speakerId: Int, startMs: Int, endMs: Int) {
        guard currentSessionRef != nil, currentUid() != nil else { return }
        hasAccumulatorPreview = true
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
        // Already null — skip the write. The live path clears on every frame that
        // carries finals but no partial, which is often several per second.
        guard hasAccumulatorPreview else { return }
        hasAccumulatorPreview = false
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
