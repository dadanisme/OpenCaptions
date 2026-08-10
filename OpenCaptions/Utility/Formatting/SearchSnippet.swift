//
//  SearchSnippet.swift
//  OpenCaptions
//
//  A short, highlighted excerpt built around a search match — "…context
//  [match] context…" — so a hit deep inside a long summary paragraph or
//  transcript line is still visible under a row's `.lineLimit`, instead of
//  being truncated before ever reaching it.
//

import Foundation
import SwiftUI

struct SearchSnippet {
    private let text: String
    private let matchRange: Range<String.Index>

    /// Finds `query` in `source` and builds a snippet centered on the first
    /// occurrence. Case/diacritic-insensitive to stay visually consistent
    /// with `localizedStandardContains`, the search used to decide a session
    /// matched in the first place — though as a plain literal-substring
    /// search it isn't guaranteed to agree with that nonliteral search in
    /// every edge case. Nil (no snippet) is a safe, silent fallback for a
    /// caller in that situation, not a crash.
    init?(source: String, query: String, contextChars: Int = 40) {
        guard let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }

        let start = source.index(range.lowerBound, offsetBy: -contextChars, limitedBy: source.startIndex)
            ?? source.startIndex
        let end = source.index(range.upperBound, offsetBy: contextChars, limitedBy: source.endIndex)
            ?? source.endIndex
        let prefix = start > source.startIndex ? "…" : ""
        let suffix = end < source.endIndex ? "…" : ""
        let snippetText = prefix + source[start..<end] + suffix

        let matchStartOffset = prefix.count + source.distance(from: start, to: range.lowerBound)
        let matchLength = source.distance(from: range.lowerBound, to: range.upperBound)
        guard let matchStart = snippetText.index(
            snippetText.startIndex, offsetBy: matchStartOffset, limitedBy: snippetText.endIndex),
            let matchEnd = snippetText.index(matchStart, offsetBy: matchLength, limitedBy: snippetText.endIndex)
        else { return nil }

        self.text = snippetText
        self.matchRange = matchStart..<matchEnd
    }

    /// The snippet as `Text`, with the matched substring bolded and tinted
    /// in `Color.accentColor` — the same system-adapting tint used for the
    /// playback-active transcript line (`MacSessionDetailView+Playback.swift`)
    /// and throughout onboarding, so a search hit reads as "this app's
    /// notion of highlighted," not a one-off color. Font size is
    /// deliberately left for the caller to set on the whole result —
    /// mirrors `HighlightedMessageText`'s convention — so this drops into
    /// any subtitle-style `Text` with only the match itself gaining weight
    /// and color.
    var highlighted: Text {
        Text(text[text.startIndex..<matchRange.lowerBound])
            + Text(text[matchRange])
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
            + Text(text[matchRange.upperBound...])
    }
}
