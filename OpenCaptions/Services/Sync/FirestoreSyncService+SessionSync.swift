//
//  FirestoreSyncService+SessionSync.swift
//  OpenCaptions
//
//  Session-document sync for FirestoreSyncService: the shared session/
//  backfill writer, speaker renames, AI summary fields, launch-time
//  reconciliation, and the shared-session password flag.
//

import Foundation
import FirebaseFirestore

extension FirestoreSyncService {

    // MARK: - Public API (session-document sync)

    /// Shared writer for both share paths: the session doc, the public
    /// `sessionIndex` lookup doc, and one line doc per backfill entry.
    ///
    /// The index doc maps the bare URL sessionId to its owner uid so
    /// `<SESSION_SHARE_BASE_URL>/<sessionId>` resolves without exposing the
    /// uid in the URL. Written once; the session doc keeps the source of
    /// truth for everything else.
    func writeSessionDocs(
        to ref: DocumentReference,
        sessionId: String,
        uid: String,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        status: String,
        speakers: [Int: String],
        backfill: [BackfillLine]
    ) {
        var speakersMap: [String: Any] = [:]
        for (id, name) in speakers {
            speakersMap[String(id)] = ["name": name]
        }

        let initialLineCount = backfill.last.map { $0.bubbleId + 1 } ?? 0
        createDoc(ref, uid: uid, data: [
            F.title: title,
            F.startedAt: Timestamp(date: startedAt),
            F.endedAt: endedAt.map { Timestamp(date: $0) as Any } ?? NSNull(),
            F.status: status,
            F.speakers: speakersMap,
            F.summary: NSNull(),
            F.shortDescription: NSNull(),
            F.lineCount: initialLineCount,
            F.accumulator: NSNull(),
        ])

        createDoc(indexDoc(for: sessionId), uid: uid, data: [
            F.ownerId: uid,
        ])

        let linesCollection = ref.collection("lines")
        for line in backfill {
            createDoc(linesCollection.document(formatLineId(line.bubbleId)), uid: uid, data: [
                F.text: line.text,
                F.speakerId: line.speakerId,
                F.startMs: line.startMs,
                F.endMs: line.endMs,
            ])
        }
    }

    /// Re-pushes a re-transcribed session's transcript to its EXISTING shared doc
    /// (#245). Keeps the same `cloudSessionId`/public link and overwrites the session
    /// doc + line docs `0..<count`, resetting `lineCount`. The web reads lines by
    /// `lineCount`, so any orphaned trailing docs left by a now-shorter transcript are
    /// ignored. This nulls the web summary (writeSessionDocs writes `summary: NSNull`);
    /// the caller re-pushes it via summary regeneration, or leaves it cleared offline —
    /// matching the local state either way. Password protection is server-owned and not
    /// touched here. No-op when signed out or `sessionSharing` is off (createDoc guard).
    func resyncSharedSession(
        cloudSessionId: String,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        speakers: [Int: String],
        backfill: [BackfillLine]
    ) {
        guard FeatureFlagService.shared.isEnabled(.sessionSharing), let uid = currentUid() else { return }
        writeSessionDocs(
            to: sessionsCollection(for: uid).document(cloudSessionId),
            sessionId: cloudSessionId,
            uid: uid,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            status: Status.ended,
            speakers: speakers,
            backfill: backfill
        )
    }

    /// Updates the per-session `speakers` map. Single field write — no fan-out
    /// across the lines subcollection (renames apply retroactively on the web
    /// because the name is resolved against this map at render time).
    ///
    /// Uses `.patch` so the dotted key is interpreted as a field path into the
    /// nested `speakers` map, surgically updating just `name` without
    /// disturbing future sibling fields under `speakers.{id}`.
    func updateSpeakerName(speakerId: Int, name: String) {
        guard let session = currentSessionRef, let uid = currentUid() else { return }
        updateDoc(session, uid: uid, data: [
            "\(F.speakers).\(speakerId).name": name,
        ], mode: .patch)
    }

    /// Patches the `speakers` map on an already-shared session doc addressed by
    /// its `cloudSessionId`. Used when speakers are renamed on a SAVED session
    /// in the detail view — unlike the live `updateSpeakerName` above, there is
    /// no `currentSessionRef` for a finished/history session, so the doc is
    /// addressed directly. No-op when signed out, when `names` is empty, or —
    /// via `updateDoc`'s internal guard — when `sessionSharing` is off. `.patch`
    /// interprets each dotted key as a field path so only `name` is touched,
    /// leaving sibling fields under `speakers.{id}` (and other speakers) intact.
    func updateSpeakerNames(cloudSessionId: String, names: [Int: String]) {
        guard !names.isEmpty, let uid = currentUid() else { return }
        let ref = sessionsCollection(for: uid).document(cloudSessionId)
        var data: [String: Any] = [:]
        for (id, name) in names {
            data["\(F.speakers).\(id).name"] = name
        }
        updateDoc(ref, uid: uid, data: data, mode: .patch)
    }

    /// Writes the AI summary fields onto an *existing* session document.
    /// Looks up the session by `cloudSessionId` (already persisted on the
    /// SwiftData row at session creation). No-op if the id is nil — that
    /// means sync was off when the session was recorded.
    ///
    /// `actionItems` is always included (even as an empty array) so that
    /// regenerating a summary that produces zero items correctly overwrites
    /// any stale list — `setData(merge: true)` deep-merges nested maps, so
    /// a missing subfield would otherwise leave the prior value in place.
    func writeSummary(
        cloudSessionId: String?,
        paragraphs: [String],
        keyPoints: [String],
        actionItems: [String],
        title: String,
        shortDescription: String
    ) {
        guard let id = cloudSessionId, let uid = currentUid() else { return }
        let ref = sessionsCollection(for: uid).document(id)
        updateDoc(ref, uid: uid, data: [
            F.title: title,
            F.shortDescription: shortDescription,
            F.summary: [
                "paragraphs": paragraphs,
                "keyPoints": keyPoints,
                "actionItems": actionItems,
            ],
        ])
    }

    /// At app launch, marks any of this user's sessions still flagged
    /// `live` or `paused` as `ended`. Defends against the iOS app crashing
    /// mid-recording without sealing the session.
    func reconcileLiveSessions() async {
        guard let uid = currentUid() else { return }
        do {
            let snap = try await sessionsCollection(for: uid)
                .whereField(F.status, in: [Status.live, Status.paused])
                .getDocuments()
            for doc in snap.documents {
                updateDoc(doc.reference, uid: uid, data: [
                    F.status: Status.ended,
                    F.endedAt: FieldValue.serverTimestamp(),
                ])
            }
        } catch {
            print("⚠️ FirestoreSync reconcile failed: \(error.localizedDescription)")
        }
    }

    /// Reads the server-owned `hasPassword` flag from `sessionIndex/{sessionId}`.
    /// Returns nil if the doc is missing/unreadable (offline, deleted) so callers
    /// keep their cached value. The client never writes this field — only the
    /// `setSessionPassword`/`removeSessionPassword` Cloud Functions flip it.
    func fetchHasPassword(cloudSessionId: String) async -> Bool? {
        do {
            let snap = try await indexDoc(for: cloudSessionId).getDocument()
            return snap.get(F.hasPassword) as? Bool
        } catch {
            print("⚠️ FirestoreSync fetchHasPassword failed: \(error.localizedDescription)")
            return nil
        }
    }
}
