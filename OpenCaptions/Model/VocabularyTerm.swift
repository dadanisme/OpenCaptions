//
//  VocabularyTerm.swift
//  OpenCaptions
//
//  One user-authored term biased into transcription — a name, product, acronym, or
//  piece of jargon that the engine otherwise mis-hears. Owned by `VocabularyStore`
//  and persisted as JSON `Data` under a single UserDefaults key (see
//  `VocabularyStore+Persistence`, which follows `HotKeyBinding`'s precedent — the
//  only other structured value this app keeps in defaults).
//
//  A struct rather than a bare `String` for two reasons: `id` gives an editor row a
//  stable identity while its text is being typed (an index- or text-keyed `ForEach`
//  loses focus on every keystroke), and per-term aliases/weights — which both Soniox
//  and FluidAudio accept — can be added later as optional properties without
//  invalidating already-persisted JSON.
//

import Foundation

struct VocabularyTerm: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }

    /// The wire form: surrounding whitespace trimmed. Empty for a freshly added row
    /// the user hasn't typed into yet — the context builder drops those.
    var normalized: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool { normalized.isEmpty }

    /// Case-insensitive dedupe key. Term biasing isn't case-sensitive, so
    /// "Nemotron" and "nemotron" are one term — sending both just wastes context
    /// budget.
    var dedupeKey: String { normalized.lowercased() }
}
