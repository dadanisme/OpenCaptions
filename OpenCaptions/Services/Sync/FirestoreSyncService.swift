//
//  FirestoreSyncService.swift
//  OpenCaptions
//
//  Mirrors live transcription sessions to Firestore so they can be viewed
//  from a read-only web client. See docs/2026-05-19-firestore-sync.md for the
//  wire format.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore
import Observation

/// Singleton that owns every Firestore write for the live-sync feature.
/// Sharing is per-session and explicit: a session starts unsynced and becomes
/// shared only when the user taps the Share button on the live view, which
/// drives `startSession(...)` here. Once started, all the bubble/speaker/
/// summary hooks fire writes for that session.
///
/// Shared sessions are publicly readable on Firestore (see `firestore.rules`).
/// Writes still require Firebase Auth as the owner.
///
/// Sync model mirrors the iOS rendering flow. The iOS UI renders two distinct
/// units stacked vertically — a list of `SpeakerBubble`s (one per committed
/// line, all styled identically), then a single `PartialSpeakerBubble` below
/// for the in-flight preview. Firestore stores those same two units:
///
/// - `lines/{lineId}` — one document per committed bubble. Uniform shape; no
///   `live`/`sealed` distinction (iOS doesn't render one). Text may still
///   grow at sentence boundaries within the most recent same-speaker bubble
///   (matching iOS's `appendOrAdd` behaviour); web simply re-renders.
/// - `session.accumulator` — current in-flight preview (Soniox partial +
///   iOS-side sentence accumulator). Throttled to 1 write/sec. Cleared the
///   moment the partial graduates into a committed line, and on
///   pause/end. Web renders this as a separate preview bubble below the
///   lines list — *not* joined to any line.
///
/// Threading: all public methods must be called from the main actor — the
/// accumulator throttle uses `CFAbsoluteTimeGetCurrent()` and an internal
/// `DispatchWorkItem` that is created/cancelled without locking.
@MainActor
final class FirestoreSyncService {

    static let shared = FirestoreSyncService()

    private init() {
        // Watch the sessionSharing flag so a mid-session disable can gracefully
        // seal the active shared session. See `observeSessionSharingFlag()`.
        observeSessionSharingFlag()
    }

    // MARK: - Tunables

    /// Maximum upsert rate for the in-flight `accumulator` field. Bounded at
    /// one write per second; trailing flush ensures the last keystroke lands.
    static let accumulatorMinInterval: CFAbsoluteTime = 1.0

    /// Zero-padding width for lineId so lexical order matches numeric order.
    /// 6 digits supports a single session with up to 999,999 bubbles.
    static let lineIdPadding: Int = 6

    // MARK: - Constants (Firestore field names)

    enum F {
        static let title = "title"
        static let startedAt = "startedAt"
        static let endedAt = "endedAt"
        static let status = "status"
        static let speakers = "speakers"
        static let summary = "summary"
        static let shortDescription = "shortDescription"
        static let lineCount = "lineCount"
        static let accumulator = "accumulator"
        static let text = "text"
        static let speakerId = "speakerId"
        static let startMs = "startMs"
        static let endMs = "endMs"
        static let createdAt = "createdAt"
        static let createdBy = "createdBy"
        static let updatedAt = "updatedAt"
        static let updatedBy = "updatedBy"
        static let ownerId = "ownerId"
        static let hasPassword = "hasPassword"
        static let isOfflineModeEnabled = "isOfflineModeEnabled"
        // Marketing-communications consent on the `users/{uid}` doc (#251). The email
        // itself is NOT mirrored here — it already lives in Firebase Auth; the backend
        // joins consent to the auth email by uid.
        static let marketingOptIn = "marketingOptIn"
    }

    /// Session-level status only — there is no per-line status.
    enum Status {
        static let live = "live"
        static let paused = "paused"
        static let ended = "ended"
    }

    // MARK: - Per-session state

    /// Reference to the active session document, or nil when sync is disabled
    /// for the current recording. All public methods short-circuit on nil.
    var currentSessionRef: DocumentReference?

    /// Snapshot of the in-flight (partial+sentence-accumulator) text and the
    /// throttle bookkeeping for writes to the session doc's `accumulator`
    /// field. Snapshots are coalesced; only the most recent one is ever sent.
    struct AccumulatorSnapshot {
        let text: String
        let speakerId: Int
        let startMs: Int
        let endMs: Int
    }
    var pendingAccumulator: AccumulatorSnapshot?

    /// Last time we wrote to the `accumulator` field; gates the 1-write/sec
    /// throttle.
    var lastAccumulatorWrite: CFAbsoluteTime = 0

    /// Pending trailing flush of the accumulator. Cancelled when superseded
    /// by an actual write, by a line commit, or by `endSession()`.
    var pendingAccumulatorFlush: DispatchWorkItem?

    // MARK: - Public API

    /// Snapshot of a line that already exists in the in-memory `TranscriberModel`
    /// at the moment the user taps Share. The service writes these as sealed
    /// historical lines and marks the last one as `live` so the next bubble
    /// update flows seamlessly into the existing throttle path.
    struct BackfillLine {
        let text: String
        let speakerId: Int
        let startMs: Int
        let endMs: Int
        let bubbleId: Int
    }

    /// Begins mirroring a recording. Returns the cloud session id if a
    /// Firebase UID is available, otherwise nil — the caller (the user-facing
    /// Share button) should disable the action when nil is returned.
    ///
    /// - Parameters:
    ///   - speakers: any speaker-id → name renames already applied locally.
    ///     Written into the session doc's `speakers` map so the web client
    ///     resolves them on first render.
    ///   - backfill: every line currently in memory (or pulled from SwiftData
    ///     by the caller). All but the last are written as `sealed`; the
    ///     last is written as `live` and becomes the throttled hot bubble.
    @discardableResult
    func startSession(
        title: String,
        startedAt: Date,
        speakers: [Int: String] = [:],
        backfill: [BackfillLine] = []
    ) -> String? {
        // Feature off: mint nothing. Returning nil (same contract as signed-out)
        // keeps the caller from persisting a phantom cloudSessionId with no
        // backing doc, since the writes below would be dropped by `createDoc`.
        guard FeatureFlagService.shared.isEnabled(.sessionSharing) else {
            currentSessionRef = nil
            return nil
        }
        guard let uid = currentUid() else {
            currentSessionRef = nil
            return nil
        }

        let sessionId = UUID().uuidString
        let ref = sessionsCollection(for: uid).document(sessionId)
        currentSessionRef = ref
        pendingAccumulator = nil
        lastAccumulatorWrite = 0
        pendingAccumulatorFlush?.cancel()
        pendingAccumulatorFlush = nil

        writeSessionDocs(
            to: ref,
            sessionId: sessionId,
            uid: uid,
            title: title,
            startedAt: startedAt,
            endedAt: nil,
            status: Status.live,
            speakers: speakers,
            backfill: backfill
        )

        return sessionId
    }

    /// Uploads an already-finished session as a shared (publicly viewable)
    /// transcript. Same wire format as `startSession(...)`, but the session
    /// doc is written directly with `status: "ended"` — viewers see a
    /// finished transcript with no in-flight accumulator/preview — and none
    /// of the live-sync state (`currentSessionRef`, throttle) is touched, so
    /// calling this never interferes with a concurrent live recording.
    ///
    /// Returns the new cloud session id, or nil if no Firebase UID is
    /// available (user signed out).
    @discardableResult
    func shareEndedSession(
        title: String,
        startedAt: Date,
        endedAt: Date,
        speakers: [Int: String],
        backfill: [BackfillLine]
    ) -> String? {
        // Feature off: mint nothing (see `startSession`).
        guard FeatureFlagService.shared.isEnabled(.sessionSharing) else { return nil }
        guard let uid = currentUid() else { return nil }

        let sessionId = UUID().uuidString
        let ref = sessionsCollection(for: uid).document(sessionId)

        writeSessionDocs(
            to: ref,
            sessionId: sessionId,
            uid: uid,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            status: Status.ended,
            speakers: speakers,
            backfill: backfill
        )

        return sessionId
    }

    func pauseSession() {
        guard let session = currentSessionRef, let uid = currentUid() else { return }
        // Drop the in-flight preview — nothing should be growing while paused.
        pendingAccumulator = nil
        pendingAccumulatorFlush?.cancel()
        pendingAccumulatorFlush = nil
        updateDoc(session, uid: uid, data: [
            F.status: Status.paused,
            F.accumulator: NSNull(),
        ])
    }

    func resumeSession() {
        guard let session = currentSessionRef, let uid = currentUid() else { return }
        updateDoc(session, uid: uid, data: [F.status: Status.live])
    }

    /// Marks the session ended and clears the in-flight `accumulator` field.
    /// Line documents need no per-end mutation — they were already in their
    /// committed state.
    func endSession() {
        guard let session = currentSessionRef, let uid = currentUid() else { return }
        pendingAccumulator = nil
        pendingAccumulatorFlush?.cancel()
        pendingAccumulatorFlush = nil

        updateDoc(session, uid: uid, data: [
            F.status: Status.ended,
            F.endedAt: FieldValue.serverTimestamp(),
            F.accumulator: NSNull(),
        ])

        currentSessionRef = nil
        lastAccumulatorWrite = 0
    }

    // MARK: - Feature-flag kill switch (graceful stop)

    /// Arms a one-shot `withObservationTracking` on the `sessionSharing` flag
    /// and re-arms itself after each change, giving the service a live reaction
    /// to remote flips without coupling the generic `FeatureFlagService` to
    /// this feature. `onChange` fires in the observed property's `willSet`
    /// (old value still current), so the resolved value is read on the next
    /// main-actor tick before deciding whether to tear down.
    private func observeSessionSharingFlag() {
        withObservationTracking {
            _ = FeatureFlagService.shared.isEnabled(.sessionSharing)
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !FeatureFlagService.shared.isEnabled(.sessionSharing) {
                    self.handleSessionSharingDisabled()
                }
                self.observeSessionSharingFlag()
            }
        }
    }

    /// Graceful stop when `sessionSharing` is turned off mid-session: seals the
    /// currently-shared session to `ended` with a concrete `endedAt` and clears
    /// the in-flight preview — one write, via the guard-bypassing `forceUpdate`
    /// (every other write path is blocked by the flag) so viewers see a
    /// finished transcript rather than a doc stuck at `live`. Then nils
    /// `currentSessionRef` so all subsequent writes short-circuit.
    ///
    /// Idempotent and safe to call when nothing is being shared (no-op). Once
    /// stopped, re-enabling the flag does not auto-resume this session — sync
    /// stays off until a fresh Share. See docs/2026-07-03-gate-session-sharing.md.
    func handleSessionSharingDisabled() {
        guard let session = currentSessionRef, let uid = currentUid() else {
            currentSessionRef = nil
            return
        }
        pendingAccumulator = nil
        pendingAccumulatorFlush?.cancel()
        pendingAccumulatorFlush = nil

        forceUpdate(session, uid: uid, data: [
            F.status: Status.ended,
            F.endedAt: FieldValue.serverTimestamp(),
            F.accumulator: NSNull(),
        ])

        currentSessionRef = nil
        lastAccumulatorWrite = 0
    }
}
