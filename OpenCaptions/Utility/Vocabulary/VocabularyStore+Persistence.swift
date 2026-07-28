//
//  VocabularyStore+Persistence.swift
//  OpenCaptions
//
//  UserDefaults round-trip for the custom vocabulary, split out so the codec stays
//  isolated from the editing API (the same reason `HotKeyManager+Carbon` is its own
//  file).
//
//  Follows the `HotKeyManager` precedent exactly — JSON `Data` under one key,
//  `try?`-silent, falling back to a code-level default rather than a
//  `register(defaults:)` entry (a `Data` blob can't be expressed as a sensible
//  registered default). Because of that fallback, the ABSENCE of the terms key is
//  what marks a first launch and triggers the seed; an empty array means the user
//  deliberately cleared the list and must stay empty.
//

import Foundation

extension VocabularyStore {

    // MARK: - Load

    func load() {
        let defaults = UserDefaults.standard

        // Read BEFORE the terms branch, which can call `persist()` — and `persist()`
        // writes both values, so seeding while this was still "" would clear a stored
        // note. Only reachable if the two keys ever got out of step, but the ordering
        // costs nothing.
        backgroundText = defaults.string(forKey: LiveSessionStore.vocabularyBackgroundTextKey) ?? ""

        if let data = defaults.data(forKey: LiveSessionStore.vocabularyTermsKey) {
            // Drop blanks that a quit-mid-edit left behind so the editor never opens
            // onto empty rows.
            let decoded = (try? JSONDecoder().decode([VocabularyTerm].self, from: data)) ?? []
            terms = decoded.filter { !$0.isBlank }
        } else {
            // First launch on a build that has a vocabulary: carry over the terms the
            // old hardcoded list biased, now visible and deletable.
            terms = Self.seedTerms.map { VocabularyTerm(text: $0) }
            persist()
        }
    }

    // MARK: - Save

    /// Writes the current vocabulary. Called after every mutation — the lists are
    /// small and `UserDefaults` coalesces its own disk writes, so there's nothing to
    /// debounce. Blank rows are excluded: they're an editor affordance, not data.
    func persist() {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(terms.filter { !$0.isBlank }) {
            defaults.set(data, forKey: LiveSessionStore.vocabularyTermsKey)
        }

        let trimmed = backgroundText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Remove rather than store "" so a cleared note doesn't shadow a future
            // default, matching how the terms key signals "never set".
            defaults.removeObject(forKey: LiveSessionStore.vocabularyBackgroundTextKey)
        } else {
            defaults.set(trimmed, forKey: LiveSessionStore.vocabularyBackgroundTextKey)
        }
    }
}
