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

/// Singleton that owns every Firestore write for the live-sync feature.
/// Sharing is per-session and explicit: a session starts unsynced and becomes
/// shared only when the user taps the Share button on the live view, which
/// drives `startSession(...)` here. Once started, all the bubble/speaker/
/// summary hooks fire writes for that session.
///
/// Shared sessions are publicly readable on Firestore (see `firestore.rules`).
/// Writes still require Firebase Auth as the owner.
///
/// The sync model renders two distinct
/// units stacked vertically — a list of `SpeakerBubble`s (one per committed
/// line, all styled identically), then a single `PartialSpeakerBubble` below
/// for the in-flight preview. Firestore stores those same two units:
///
/// - `lines/{lineId}` — one document per committed bubble. Uniform shape; no
///   `live`/`sealed` distinction. The most recent same-speaker bubble keeps
///   growing as tokens are committed (an append-or-add behaviour), so
///   same-bubble updates are throttled to 1 write/sec with a trailing flush;
///   web simply re-renders.
/// - `session.accumulator` — current in-flight preview (the engine's
///   un-finalized partial). Throttled to 1 write/sec. Cleared the
///   moment the partial graduates into committed lines, and on
///   pause/end. Web renders this as a separate preview bubble below the
///   lines list — *not* joined to any line.
///
/// Threading: all public methods must be called from the main actor — both
/// throttles use `CFAbsoluteTimeGetCurrent()` and internal
/// `DispatchWorkItem`s that are created/cancelled without locking.
@MainActor
final class FirestoreSyncService {

    static let shared = FirestoreSyncService()

    private init() {}

    // MARK: - Tunables

    /// Maximum upsert rate for the in-flight `accumulator` field. Bounded at
    /// one write per second; trailing flush ensures the last keystroke lands.
    static let accumulatorMinInterval: CFAbsoluteTime = 1.0

    /// Maximum update rate for the OPEN line document. The live path commits one
    /// finalized token at a time, so a same-speaker bubble grows several times a
    /// second; without this each token would be its own write (well past
    /// Firestore's ~1 write/sec/document guidance). A trailing flush, plus a
    /// forced flush when the next bubble opens or the session pauses/ends,
    /// guarantees the bubble's final text always lands.
    static let lineUpdateMinInterval: CFAbsoluteTime = 1.0

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
        // Marketing-communications consent on the `users/{uid}` doc. The email
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

    /// Snapshot of the in-flight preview text (the engine's un-finalized partial)
    /// and the throttle bookkeeping for writes to the session doc's `accumulator`
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

    /// Whether the `accumulator` field currently holds a preview (or has a pending
    /// write that will put one there). Lets `clearAccumulator()` no-op when the field
    /// is already null: the live path asks it to clear on every frame that carries
    /// finals but no partial, and that clear is deliberately unthrottled, so without
    /// this a finalization burst would be one wasted write per frame.
    var hasAccumulatorPreview = false

    /// Coalesced growth of the currently-open line document. Only the most recent
    /// snapshot is ever sent; `lineId` is carried so a flush after the next bubble
    /// opened still targets the right document.
    struct LineUpdateSnapshot {
        let lineId: String
        let text: String
        let endMs: Int
    }
    var pendingLineUpdate: LineUpdateSnapshot?

    /// Last time we wrote the open line document; gates the 1-write/sec throttle.
    var lastLineUpdateWrite: CFAbsoluteTime = 0

    /// Pending trailing flush of the open line. Cancelled when superseded by an
    /// actual write, by a new bubble, or by pause/end.
    var pendingLineUpdateFlush: DispatchWorkItem?

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
        pendingLineUpdate = nil
        lastLineUpdateWrite = 0
        pendingLineUpdateFlush?.cancel()
        pendingLineUpdateFlush = nil
        hasAccumulatorPreview = false

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
}
