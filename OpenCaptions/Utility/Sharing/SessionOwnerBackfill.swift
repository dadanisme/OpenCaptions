//
//  SessionOwnerBackfill.swift
//  OgmoMac
//
//  One-time launch migration: attributes legacy sessions (recorded before auth
//  existed on macOS, so `userId == nil`) to the currently signed-in user, so the
//  per-user query shows them to their owner. Ported verbatim from the iOS enum.
//

import Foundation
import SwiftData

enum SessionOwnerBackfill {
    /// Assigns `userId` to legacy sessions that have none, on a background context.
    /// Cheap no-op once every session is owned (or when no user is signed in).
    static func run(container: ModelContainer, userId: String?) async {
        guard let userId else { return }
        await reassign(container: container, from: nil, to: userId, label: "Backfilled")
    }

    /// Moves a local guest's sessions (owner `MacAuthManager.guestOwnerId`) to the
    /// account they just signed into — the explicit "keep my offline transcriptions"
    /// upgrade from Settings. Unlike `run`, this is only ever triggered by that
    /// deliberate action, never automatically at launch, so it can't silently absorb
    /// a shared Mac's guest history into an unrelated account.
    static func claimGuestSessions(container: ModelContainer, userId: String) async {
        let guestID = MacAuthManager.guestOwnerId
        guard userId != guestID else { return }
        await reassign(container: container, from: guestID, to: userId, label: "Migrated guest")
    }

    /// Reassigns every session owned by `owner` to `newOwner` on a background
    /// context. `owner == nil` matches the pre-auth legacy rows. Builds the fetch
    /// predicate by branching on nil vs a concrete owner rather than capturing an
    /// optional (a `#Predicate` sharp edge).
    private static func reassign(
        container: ModelContainer, from owner: String?, to newOwner: String, label: String
    ) async {
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let predicate: Predicate<TranscriptionSession>
            if let owner {
                predicate = #Predicate { $0.userId == owner }
            } else {
                predicate = #Predicate { $0.userId == nil }
            }
            let descriptor = FetchDescriptor<TranscriptionSession>(predicate: predicate)

            guard let sessions = try? context.fetch(descriptor), !sessions.isEmpty else { return }

            for session in sessions {
                session.userId = newOwner
            }

            do {
                try context.save()
                print("✅ \(label) owner for \(sessions.count) session(s)")
            } catch {
                print("❌ Session-owner reassignment failed: \(error.localizedDescription)")
            }
        }
        await task.value
    }
}
