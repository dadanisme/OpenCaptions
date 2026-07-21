//
//  SentenceHeuristics.swift
//  OgmoMac
//
//  Pure, CJK-aware sentence/word heuristics shared by the LIVE token accumulator
//  (`MacTranscriptionViewModel+Accumulator`) and the BATCH post-session segment
//  builder (`PostSessionSegmentBuilder`). Extracted so the two line-grouping paths
//  can never drift on what counts as a word or a sentence boundary.
//

import Foundation

/// Stateless text heuristics for grouping transcription tokens into lines.
enum SentenceHeuristics {

    /// Counts whitespace-separated words.
    static func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// True for ideographic/syllabic scripts written without inter-word spaces.
    static func isSpacelessScript(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)   // Hiragana + Katakana
                || (0x3400...0x4DBF).contains(scalar.value)   // CJK Extension A
                || (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified Ideographs
                || (0xF900...0xFAFF).contains(scalar.value)   // CJK Compatibility Ideographs
                || (0xAC00...0xD7AF).contains(scalar.value)   // Hangul Syllables
        }
    }

    /// A space-delimited word character (letter, not from a space-less script).
    static func isWordCharacter(_ ch: Character?) -> Bool {
        guard let ch, ch.isLetter else { return false }
        return !isSpacelessScript(ch)
    }

    /// Whether text ends a complete sentence (Latin `.!?`, CJK `。！？`, and a
    /// closing quote right after a terminator), ignoring text inside open quotes.
    static func endsWithSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }

        let sentenceEnders: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
        let closingQuotes: Set<Character> = ["\"", "\u{201D}", "\u{2019}", "'"]

        if !sentenceEnders.contains(last) {
            guard closingQuotes.contains(last),
                  let prev = trimmed.dropLast().last,
                  sentenceEnders.contains(prev) else {
                return false
            }
        }

        let quoteChars: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        let quoteCount = trimmed.filter { quoteChars.contains($0) }.count
        return quoteCount % 2 == 0
    }
}
