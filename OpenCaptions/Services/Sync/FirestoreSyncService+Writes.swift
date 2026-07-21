//
//  FirestoreSyncService+Writes.swift
//  OgmoMac
//
//  Firestore path helpers and low-level write primitives for
//  FirestoreSyncService. Audit fields are stamped here, never inline.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

extension FirestoreSyncService {

    // MARK: - Internals

    func currentUid() -> String? {
        // Prefer the live Auth state — MacAuthManager caches the last-known uid in
        // UserDefaults, which can lag a forced sign-out by one event loop.
        Auth.auth().currentUser?.uid ?? MacAuthManager.shared.userID
    }

    /// Per-user sessions live nested under `users/{uid}/sessions/{sessionId}`.
    /// The public share URL is `https://session.ogmo.app/<sessionId>` — the web
    /// client first reads the small `sessionIndex/{sessionId}` doc to resolve
    /// the URL's bare sessionId to its owner uid, then subscribes to the
    /// nested path. See `indexDoc(for:)` and `2026-05-19-web-client-prompt.md`.
    func sessionsCollection(for uid: String) -> CollectionReference {
        Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("sessions")
    }

    /// Top-level public index that maps a bare `sessionId` to its owner uid.
    /// Written once at `startSession`; read once by the web client to resolve
    /// the share URL into a nested path. The doc body is small on purpose.
    func indexDoc(for sessionId: String) -> DocumentReference {
        Firestore.firestore().collection("sessionIndex").document(sessionId)
    }

    func formatLineId(_ bubbleId: Int) -> String {
        String(format: "%0\(Self.lineIdPadding)d", bubbleId)
    }

    // MARK: - Write helpers (audit fields are stamped here, never inline)

    /// Inserts a brand-new document, stamping all four audit fields. Uses
    /// `merge: false` because a fresh insert should never accidentally
    /// preserve garbage from a previous lifecycle.
    ///
    /// Feature-flag kill switch: every routine share write funnels through
    /// here and `updateDoc`, so a single guard stops ALL Firestore share
    /// writes when `sessionSharing` is off. The one exception is the graceful
    /// seal fired by `handleSessionSharingDisabled()`, which uses
    /// `forceUpdate` to bypass this guard. See docs/2026-07-03-gate-session-sharing.md.
    func createDoc(_ ref: DocumentReference, uid: String, data: [String: Any]) {
        guard FeatureFlagService.shared.isEnabled(.sessionSharing) else { return }
        var payload = data
        let now = FieldValue.serverTimestamp()
        payload[F.createdAt] = now
        payload[F.createdBy] = uid
        payload[F.updatedAt] = now
        payload[F.updatedBy] = uid
        ref.setData(payload, merge: false) { error in
            if let error {
                print("⚠️ FirestoreSync create failed: \(error.localizedDescription)")
            }
        }
    }

    /// How `updateDoc` should write its payload. The two modes differ in how
    /// dotted keys are interpreted by Firestore.
    enum UpdateMode {
        /// `setData(merge: true)`. Nested maps are deep-merged and
        /// `createdAt`/`createdBy` are preserved. Dotted keys are stored as
        /// **literal** field names — use when the payload is flat or already
        /// nested as a dictionary.
        case merge
        /// `updateData(...)`. Dotted keys are field paths, surgically patching
        /// nested fields without overwriting siblings. Fails if the document
        /// does not yet exist.
        case patch
    }

    /// Patches an existing document, refreshing only `updatedAt`/`updatedBy`.
    func updateDoc(
        _ ref: DocumentReference,
        uid: String,
        data: [String: Any],
        mode: UpdateMode = .merge
    ) {
        // Kill switch — see `createDoc` above.
        guard FeatureFlagService.shared.isEnabled(.sessionSharing) else { return }
        var payload = data
        payload[F.updatedAt] = FieldValue.serverTimestamp()
        payload[F.updatedBy] = uid
        let completion: (Error?) -> Void = { error in
            if let error {
                print("⚠️ FirestoreSync update failed: \(error.localizedDescription)")
            }
        }
        switch mode {
        case .merge:
            ref.setData(payload, merge: true, completion: completion)
        case .patch:
            ref.updateData(payload, completion: completion)
        }
    }

    /// Merge-writes a document **without** the `sessionSharing` kill switch.
    /// Reserved for the single graceful-seal write in
    /// `handleSessionSharingDisabled()` — the one write we intentionally let
    /// through after the flag turns off, so an in-flight shared session is
    /// closed to `ended` rather than left stuck at `live`. Otherwise identical
    /// to `updateDoc(.merge)`; do not use it for routine writes.
    func forceUpdate(_ ref: DocumentReference, uid: String, data: [String: Any]) {
        var payload = data
        payload[F.updatedAt] = FieldValue.serverTimestamp()
        payload[F.updatedBy] = uid
        ref.setData(payload, merge: true) { error in
            if let error {
                print("⚠️ FirestoreSync graceful seal failed: \(error.localizedDescription)")
            }
        }
    }
}
