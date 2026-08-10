//
//  VocabularyStore.swift
//  OpenCaptions
//
//  App-level owner of the user's CUSTOM VOCABULARY: the terms biased into
//  recognition, plus an optional freeform background note. Before this existed the
//  bias list was a literal hardcoded in two places (the live Soniox config and the
//  async re-transcription request), so a user could not add a single name.
//
//  Device-local by design — there is no backend to sync it to, and syncing it
//  safely would need read-before-write plumbing this app doesn't have.
//
//  `@Observable @MainActor` singleton (the `HotKeyManager` pattern) so the
//  Vocabulary screen re-renders as the list is edited. The context it hands
//  the engines is built in `VocabularyStore+SonioxContext`; persistence lives
//  in `VocabularyStore+Persistence`.
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

    /// The user's terms in add order. `addTerms` rejects blanks, so entries here are
    /// non-blank in practice; the blank filtering in `+Persistence` and the context
    /// builder is defensive, and cleans up anything left by the earlier row-editor
    /// design (which allowed a blank row while it was being typed into).
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

    /// Adds every term in `input` that isn't already covered, and returns how many
    /// were added. `input` is split on commas and newlines, so pasting a list adds it
    /// in one go; blanks, in-batch repeats, and anything already covered by the list /
    /// a built-in / the display name are skipped.
    @discardableResult
    func addTerms(from input: String, userName: String?) -> Int {
        let additions = newTerms(in: input, userName: userName)
        guard !additions.isEmpty else { return 0 }
        terms.append(contentsOf: additions.map { VocabularyTerm(text: $0) })
        persist()
        return additions.count
    }

    func removeTerm(_ id: UUID) {
        terms.removeAll { $0.id == id }
        persist()
    }

    func setBackgroundText(_ text: String) {
        backgroundText = text
        persist()
    }

    // MARK: - Add-field support

    /// The terms `input` would actually contribute, in order — what the Add button
    /// commits, and what tells the screen whether there is anything to add at all
    /// (so it can say "already in your list" instead of no-oping silently).
    func newTerms(in input: String, userName: String?) -> [String] {
        var covered = Set(Self.builtInTerms.map { $0.lowercased() })
        if let name = Self.normalizedName(userName) {
            covered.insert(name.lowercased())
        }
        for term in terms where !term.isBlank {
            covered.insert(term.dedupeKey)
        }

        var additions: [String] = []
        for candidate in Self.splitCandidates(input) {
            guard covered.insert(candidate.lowercased()).inserted else { continue }
            additions.append(candidate)
        }
        return additions
    }

    /// Splits raw field input into candidate terms on commas and newlines — the two
    /// separators a pasted list realistically uses. A term containing a comma isn't
    /// supported, which is the usual trade in a tag field.
    static func splitCandidates(_ input: String) -> [String] {
        input
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Terms always sent on top of the user's list, for the screen to show as
    /// non-removable chips: the app's built-ins plus the display name.
    func alwaysIncludedTerms(userName: String?) -> [String] {
        Self.builtInTerms + (Self.normalizedName(userName).map { [$0] } ?? [])
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
