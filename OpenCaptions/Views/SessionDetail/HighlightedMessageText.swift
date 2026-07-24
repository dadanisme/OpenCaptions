//
//  HighlightedMessageText.swift
//  OpenCaptions
//
//  Renders transcript text with two layered highlights:
//  • Question sentences get a `Color.DS.questionHighlight` background tint.
//  • Mentions of the signed-in user's name render as a bold `@Name` so the user
//    can spot when they were addressed. Name wins where the two
//    overlap.
//  Detection is purely string-based — there is no model flag and no schema change;
//  the sentence scanner + name matcher live in the `+Caching` file.
//
//  Font and text color are intentionally NOT set on the rendered runs, so they are
//  inherited from the surrounding view's `.font(...)` / foreground style. This lets
//  it drop in wherever a plain `Text(line)` was used with zero change to sizing or
//  foreground — only questions gain a background tint and only the name gains bold.
//

import SwiftUI

struct HighlightedMessageText: View {
    let message: String
    /// The signed-in user's display name, whose whole-word mentions render as a
    /// bold `@Name`. Nil/blank (e.g. an offline guest, who has no account) simply
    /// disables name highlighting — questions still highlight. Passed explicitly:
    /// macOS has no global `UserSettings.userName`, so the source is
    /// `MacAuthManager.shared.userName` at each call site.
    let userName: String?
    /// Whether this line reads/writes the shared `segmentCache`. The live partial
    /// line streams a fresh string on every token, so it is rendered with
    /// `cached: false` — it parses each time but stays OUT of the cache. Otherwise
    /// its hundreds of ephemeral permutations would churn the 200-entry cache and
    /// evict the still-visible committed-line entries.
    let shouldCache: Bool

    // MARK: - Caching

    /// Cache parsed segments keyed by `"message|userName"`. Question detection is a
    /// pure function of the string, but name detection also depends on the current
    /// user's name, so the key includes it — two users on a shared Mac never collide.
    static var segmentCache: [String: [TextSegment]] = [:]

    /// Compiled `\bname\b` regexes keyed by the lowercased/trimmed name, so a name
    /// is compiled once and reused across every line in a session. Populated by
    /// `findNameRanges` via `NameMentionMatcher.regex(for:)`.
    static var regexCache: [String: NSRegularExpression] = [:]

    /// Maximum segment cache entries before eviction.
    static let maxCacheSize = 200

    /// Straight and curly quote characters, tracked so a `?` inside a quotation
    /// highlights from the opening quote and includes the closing one.
    static let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]

    init(_ message: String, userName: String? = nil, cached: Bool = true) {
        self.message = message
        self.userName = userName
        self.shouldCache = cached
    }

    var body: some View {
        let segments = parseMessage()
        // Fast path: nothing to highlight → a plain `Text` so the font and
        // foreground inherit exactly as before (the overwhelmingly common case,
        // and identical to the pre-port rendering).
        if segments.count == 1 && segments[0].type == .normal {
            Text(message)
        } else {
            Text(buildAttributedString(from: segments))
        }
    }
}

#Preview("HighlightedMessageText") {
    VStack(alignment: .leading, spacing: 16) {
        HighlightedMessageText("This line has no question so it renders plain.")
        HighlightedMessageText("Statement first. Then a question? And a trailing statement.")
        HighlightedMessageText("The reading was 7.6 today. Did it change at all?")
        HighlightedMessageText("She asked, \u{201C}Are you coming with us?\u{201D} and left.")
        HighlightedMessageText("Hey Ramdan, can you take this one?", userName: "Ramdan")
    }
    .font(.body)
    .padding()
    .frame(width: 420, alignment: .leading)
}
