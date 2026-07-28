//
//  VocabularyStore.swift
//  OpenCaptions
//
//  App-level owner of the user's CUSTOM VOCABULARY: the terms biased into
//  recognition, plus an optional freeform background note. Before this existed the
//  bias list was a literal hardcoded in two places (the live Soniox config and the
//  async re-transcription request), so a user could not add a single name.
//
//  Device-local by design. It is NOT mirrored to Firestore: `mergeUserDoc` replaces
//  array fields wholesale, there is no snapshot listener and no launch-time
//  hydration, so a second device would silently overwrite the first device's list.
//  Syncing it safely needs read-before-write plumbing this app doesn't have yet.
//
//  `@Observable @MainActor` singleton (the `HotKeyManager` / `MacAuthManager`
//  pattern) so the Vocabulary screen re-renders as the list is edited. The context
//  it hands the engines is built in `VocabularyStore+SonioxContext`; persistence
//  lives in `VocabularyStore+Persistence`.
//

import Foundation
import Observation

@Observable
@MainActor
final class VocabularyStore {
    static let shared = VocabularyStore()

    /// Loads eagerly in `init` rather than behind a `start()` the app calls — unlike
    /// `HotKeyManager`, which must defer because it installs Carbon handlers. A
    /// session can be started from the MENU BAR with the main window never opened, so
    /// anything hung off the window's launch task could be skipped, and a vocabulary
    /// that silently didn't load is invisible to the user. Reading defaults has no
    /// ordering constraint, so the first `.shared` touch is a safe place to do it.
    private init() {
        load()
    }

    /// The user's terms in editor order. Blank entries are legal here — a freshly
    /// added row is blank until typed into — and are dropped when building the engine
    /// context and when persisting.
    ///
    /// Not `private(set)` only because `load()` assigns it and lives in the
    /// `+Persistence` extension file (the same reason `HotKeyManager.issues` can't
    /// be). Mutate it exclusively through the editing methods below, which persist;
    /// a direct write would silently skip the save.
    var terms: [VocabularyTerm] = []

    /// Freeform background context (Soniox `context.text`): an agenda, prior notes,
    /// or a topic description. Shares the character budget with `terms`. Same
    /// `private(set)` caveat as above — go through `setBackgroundText`.
    var backgroundText: String = ""

    // MARK: - Built-ins

    /// Terms ALWAYS sent, on top of whatever the user maintains, and not editable:
    /// the app's own nouns, which appear in its UI and are what users say when
    /// talking about it. Deliberately short — every built-in spends context budget.
    static let builtInTerms = ["Open Captions", "Soniox"]

    /// Terms the pre-vocabulary builds hardcoded that AREN'T the app's own identity.
    /// Seeded into the user's editable list on first launch so existing behavior is
    /// preserved, then owned by the user — deleting one is permanent (the seed only
    /// runs when the defaults key is absent entirely).
    static let seedTerms = ["Apple Developer Academy"]

    // MARK: - Editing

    /// Appends a blank term and returns its id so the caller can focus the new row.
    @discardableResult
    func addTerm() -> UUID {
        let term = VocabularyTerm()
        terms.append(term)
        persist()
        return term.id
    }

    /// Replaces one term's text. Stored verbatim (not trimmed) so typing a space
    /// mid-edit isn't fought by the field; trimming happens at the wire boundary.
    func updateTerm(_ id: UUID, text: String) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].text = text
        persist()
    }

    func removeTerm(_ id: UUID) {
        terms.removeAll { $0.id == id }
        persist()
    }

    func setBackgroundText(_ text: String) {
        backgroundText = text
        persist()
    }

    // MARK: - Duplicates

    /// Ids of rows whose term is already covered — by an earlier row, by a built-in,
    /// or by the display name. Duplicates are harmless on the wire (the context
    /// builder folds them) but confusing in the editor, so the screen flags them.
    /// Computed for the whole list at once rather than per row, which would be O(n²).
    func duplicateTermIDs(userName: String?) -> Set<UUID> {
        var seen = Set(Self.builtInTerms.map { $0.lowercased() })
        if let name = Self.normalizedName(userName) {
            seen.insert(name.lowercased())
        }

        var duplicates: Set<UUID> = []
        for term in terms where !term.isBlank {
            if !seen.insert(term.dedupeKey).inserted {
                duplicates.insert(term.id)
            }
        }
        return duplicates
    }

    /// The signed-in display name, trimmed, or nil when absent/blank (offline guests
    /// have no name).
    static func normalizedName(_ userName: String?) -> String? {
        guard let name = userName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return nil
        }
        return name
    }
}
