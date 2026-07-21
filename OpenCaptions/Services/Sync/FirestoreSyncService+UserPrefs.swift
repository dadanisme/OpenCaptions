//
//  FirestoreSyncService+UserPrefs.swift
//  OgmoMac
//
//  Writes to the per-user profile doc (`users/{uid}`), kept apart from the
//  session-sync writes. Covers the Offline Mode preference (#274) and the
//  marketing-consent opt-in (#251). The email itself is NOT written here — it
//  already lives in Firebase Auth; only consent (which Auth can't store) needs a
//  home. The session helpers (`createDoc`/`updateDoc`) are deliberately NOT reused
//  here: they're gated behind the `sessionSharing` feature flag and scoped to
//  session documents, whereas these fields are independent of sharing and live on
//  the user doc. See docs/2026-07-15-macos-email-capture-and-support.md.
//

import Foundation
import FirebaseFirestore

extension FirestoreSyncService {

    // MARK: - Public field writers

    /// Mirrors the Offline Mode preference to the signed-in user's Firestore doc.
    /// No-op when not authenticated (offline-only users have no account to sync to).
    func syncOfflineMode(_ enabled: Bool) {
        mergeUserDoc([F.isOfflineModeEnabled: enabled])
    }

    /// Persists the user's marketing-communications consent (#251). Opt-in: the UI
    /// defaults to off and only flips this when the user explicitly toggles it.
    func syncMarketingOptIn(_ optIn: Bool) {
        mergeUserDoc([F.marketingOptIn: optIn])
    }

    /// Reads the current marketing-consent flag for the signed-in user, defaulting
    /// to `false` (no consent) when signed out, on a read error, or when the field
    /// is absent — so the toggle only ever shows "on" for a genuine prior opt-in.
    func fetchMarketingOptIn() async -> Bool {
        guard let uid = currentUid() else { return false }
        let ref = Firestore.firestore().collection("users").document(uid)
        let snapshot = try? await ref.getDocument()
        return (snapshot?.data()?[F.marketingOptIn] as? Bool) ?? false
    }

    // MARK: - Audit-correct writer

    /// Merges `fields` into the signed-in user's profile doc, stamping audit fields
    /// correctly: `createdAt`/`createdBy` are set once — only when we DEFINITIVELY
    /// read a non-existent doc — and `updatedAt`/`updatedBy` on every write. Every
    /// `users/{uid}` write on macOS funnels through here, so the profile doc always
    /// carries all four audit fields even though no Cloud Function seeds it (the
    /// client creates it lazily on the first write). No-op when signed out.
    ///
    /// The read guards against clobbering: if `getDocument` errors (e.g. offline) we
    /// skip `createdAt`/`createdBy` rather than risk overwriting an existing
    /// server-side `createdAt` when the queued merge later syncs.
    private func mergeUserDoc(_ fields: [String: Any]) {
        guard let uid = currentUid() else { return }
        let ref = Firestore.firestore().collection("users").document(uid)
        ref.getDocument { snapshot, error in
            var payload = fields
            payload[F.updatedAt] = FieldValue.serverTimestamp()
            payload[F.updatedBy] = uid
            if error == nil, snapshot?.exists == false {
                payload[F.createdAt] = FieldValue.serverTimestamp()
                payload[F.createdBy] = uid
            }
            ref.setData(payload, merge: true) { writeError in
                if let writeError {
                    print("⚠️ user-doc write failed: \(writeError.localizedDescription)")
                }
            }
        }
    }
}
