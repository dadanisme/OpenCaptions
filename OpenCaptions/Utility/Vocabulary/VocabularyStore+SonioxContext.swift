//
//  VocabularyStore+SonioxContext.swift
//  OpenCaptions
//
//  Turns the stored vocabulary into the `SonioxConfig.Context` both cloud paths send
//  — the live WebSocket config (`MacTranscriptionViewModel.makeSonioxConfig`) and the
//  async re-transcription create request (`PostSessionRetranscriptionFactory`). This
//  is the ONE place the wire list is assembled, replacing the two hardcoded arrays
//  that used to drift apart.
//
//  Everything here CLAMPS to `SonioxConfig.Context.characterLimit`. Going over
//  doesn't degrade the hints, it fails the whole request — live, that means a session
//  that connects and transcribes nothing. So an over-long vocabulary loses its tail
//  instead of breaking the session, and the Vocabulary screen warns before it gets
//  there (it reads the UNCLAMPED `contextCharacterCount`, which is allowed to exceed
//  the cap; the clamped context never can).
//

import Foundation

extension VocabularyStore {

    // MARK: - Wire context

    /// The context to send, clamped to fit. Term priority when clamping is
    /// most-important-first: the display name, then the app's built-ins, then the
    /// user's terms in editor order — so the tail of a too-long user list is what
    /// gets dropped. The background note takes whatever budget the terms leave.
    func sonioxContext(userName: String?) -> SonioxConfig.Context {
        let all = wireTerms(userName: userName)
        let text = trimmedBackgroundText

        // Overwhelmingly the common case: everything fits, so nothing is measured
        // twice and no clamping runs.
        let full = Self.context(terms: all, text: text)
        if full.fitsCharacterLimit { return full }

        let kept = Array(all.prefix(longestFittingTermPrefix(of: all)))
        return Self.context(terms: kept, text: fittingTextPrefix(text, alongside: kept))
    }

    /// Every term that would be sent, deduped case-insensitively and with blanks
    /// dropped, in clamp-priority order. The display name leads because the
    /// name-mention highlight + notify match the transcript literally — a mis-heard
    /// name means no highlight and no alert — so it is the term least worth losing.
    func wireTerms(userName: String?) -> [String] {
        var candidates: [String] = []
        if let name = Self.normalizedName(userName) {
            candidates.append(name)
        }
        candidates.append(contentsOf: Self.builtInTerms)
        candidates.append(contentsOf: terms.map(\.normalized))

        var ordered: [String] = []
        var seen = Set<String>()
        for term in candidates where !term.isEmpty {
            guard seen.insert(term.lowercased()).inserted else { continue }
            ordered.append(term)
        }

        return ordered
    }

    // MARK: - Budget

    /// Size of everything the user has entered, UNCLAMPED — so the screen can show
    /// them exceeding the cap (the clamped context never can). Callers compare against
    /// `SonioxConfig.Context.characterLimit` themselves rather than calling a second
    /// helper here, so rendering the meter costs one serialization, not two.
    func contextCharacterCount(userName: String?) -> Int {
        Self.context(terms: wireTerms(userName: userName), text: trimmedBackgroundText)
            .characterCount
    }

    // MARK: - Clamping

    private var trimmedBackgroundText: String {
        backgroundText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func context(terms: [String], text: String) -> SonioxConfig.Context {
        SonioxConfig.Context(
            general: SonioxConfig.Context.appGeneralEntries,
            terms: terms,
            text: text.isEmpty ? nil : text
        )
    }

    /// Length of the longest prefix of `all` that still fits with no background text.
    /// Binary search rather than an append-and-measure loop: serialized length grows
    /// monotonically with the prefix, so this costs O(log n) measurements instead of
    /// O(n) — and an over-budget list can hold thousands of short terms.
    private func longestFittingTermPrefix(of all: [String]) -> Int {
        var low = 0  // known to fit (the general hints alone always do)
        var high = all.count  // may not

        while low < high {
            let mid = (low + high + 1) / 2
            if Self.context(terms: Array(all.prefix(mid)), text: "").fitsCharacterLimit {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return low
    }

    /// The longest prefix of `text` that fits alongside `terms`, or nil when not even
    /// one character does. Truncation is by character, not word — the note is a
    /// recognition hint, never displayed, so a clipped final word costs nothing.
    private func fittingTextPrefix(_ text: String, alongside terms: [String]) -> String {
        guard !text.isEmpty else { return "" }
        if Self.context(terms: terms, text: text).fitsCharacterLimit { return text }

        var low = 0
        var high = text.count

        while low < high {
            let mid = (low + high + 1) / 2
            if Self.context(terms: terms, text: String(text.prefix(mid))).fitsCharacterLimit {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return String(text.prefix(low))
    }
}
