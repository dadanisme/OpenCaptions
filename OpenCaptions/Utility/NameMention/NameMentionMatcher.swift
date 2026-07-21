//
//  NameMentionMatcher.swift
//  OgmoMac
//
//  Word-boundary, case-insensitive matcher for the signed-in user's display name.
//  The single source of truth for how a name becomes a regex, shared by the two
//  places that need it (issue #255): the transcript highlight
//  (`HighlightedMessageText`, which caches the compiled regex for per-line render
//  speed) and the name-mention notifier (`MacNameMentionNotifier`, which only needs
//  a yes/no per finalized sentence). Stateless, so it is safe to call from any actor
//  and needs no isolation.
//

import Foundation

enum NameMentionMatcher {
    /// A case-insensitive `\bname\b` regex for `name`, or nil if `name` is empty
    /// after lowercasing + whitespace-trimming — a blank name must never compile to
    /// a pattern that matches everything. The name is regex-escaped, so any
    /// punctuation or regex metacharacter in it stays literal.
    static func regex(for name: String) -> NSRegularExpression? {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: normalized))\\b"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    /// True if `name` appears as a whole word in `text` (case-insensitive). Returns
    /// false for a blank name.
    static func containsMention(of name: String, in text: String) -> Bool {
        guard let regex = regex(for: name) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
