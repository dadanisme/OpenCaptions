//
//  LiveLineCursor.swift
//  OpenCaptions
//
//  Where the live transcript currently stands, so the NEXT finalized token knows
//  whether it merges into the open bubble, opens a paragraph inside it, or starts a
//  new bubble.
//
//  Deliberately holds **no text**: every finalized token is committed to
//  `TranscriberModel` the moment it arrives (see `MacTranscriptionViewModel+Lines`),
//  so this is pure presentation bookkeeping and never gates when text becomes
//  visible. That is the whole difference from the deleted `AccumulatorState`, which
//  buffered finalized text until a sentence boundary.
//  See docs/2026-07-29-macos-live-line-building.md.
//

import Foundation

/// Grouping cursor for the live, per-token line builder.
struct LiveLineCursor {

    /// Where a finalized token belongs relative to the open bubble.
    enum Placement {
        /// Append to the open bubble's current paragraph.
        case merge
        /// Open a new paragraph (`\n\n`) inside the open bubble.
        case newParagraph
        /// Start a new bubble.
        case newBubble
    }

    // MARK: - Open bubble

    /// Speaker the open bubble belongs to; nil when no bubble is open yet. This is
    /// the "no bubble yet" signal — `TranscriptionToken.unknownSpeaker` keeps its
    /// single meaning of "diarization unavailable" and is never overloaded here.
    private(set) var speaker: Int?

    /// Source app the open bubble is attributed to (nil = mic / attribution off).
    private(set) var sourceApp: String?

    /// Words committed into the open bubble's current paragraph.
    private(set) var paragraphWords = 0

    /// Paragraphs already closed inside the open bubble.
    private(set) var closedParagraphs = 0

    /// Whether the last committed token closed a sentence.
    private(set) var didEndSentence = false

    /// Whether the last committed token ended on whitespace. Engines disagree about
    /// which side of a word carries the separator — Soniox puts a leading space on
    /// word tokens, while `FluidAudioStreamBridge` cuts at a word start so its
    /// finals end with one — so a seam is breakable if EITHER side has whitespace.
    /// Testing only the incoming token would block every break on the on-device path.
    private(set) var didEndWithWhitespace = false

    /// Whether the engine reported an endpoint since the last committed token
    /// (Soniox `<end>`); on-device engines emit none.
    private(set) var didSeeEndpoint = false

    /// Whether a bubble is currently open.
    var isOpen: Bool { speaker != nil }

    /// Whether the next token lands on a natural break — a finished sentence or an
    /// engine endpoint. Paragraph breaks and source-app re-checks only happen here,
    /// so a bubble is never cut mid-sentence and keeps a single app.
    var isAtSafeBreak: Bool { didEndSentence || didSeeEndpoint }

    // MARK: - Decisions

    /// Records an engine endpoint, making the next token a safe place to break even
    /// without sentence punctuation.
    mutating func noteEndpoint() { didSeeEndpoint = true }

    /// Whether the dominant source app must be re-read for this token instead of
    /// inherited from the open bubble. True when a bubble is about to open — nothing
    /// to inherit, or a speaker change starting one — and at a natural break. A
    /// bubble must reflect a single app, and the query is `O(samples)`, so a plain
    /// mid-sentence merge inherits rather than re-reads.
    func needsSourceAppRefresh(for text: String, speaker: Int) -> Bool {
        guard isOpen else { return true }
        if isAtSafeBreak { return true }
        // A mid-sentence speaker change opens a bubble, so it needs its own app —
        // punctuation-only tokens never open one and can inherit.
        return SentenceHeuristics.hasWordContent(text) && speaker != self.speaker
    }

    /// Decides where a finalized token belongs and advances the cursor as if it had
    /// been committed. `text` is the token's raw text (engine spacing intact).
    mutating func place(text: String, speaker: Int, sourceApp: String?) -> Placement {
        // Punctuation-only tokens stay with the text they punctuate: engines
        // sometimes attribute a bare "." to a different (or unknown) speaker, and
        // breaking there would strand a one-character bubble or a leading period.
        // They also count as zero words, so a period doesn't shorten a paragraph.
        let carriesWords = SentenceHeuristics.hasWordContent(text)
        let words = carriesWords ? SentenceHeuristics.countWords(in: text) : 0

        let placement: Placement
        if !isOpen {
            placement = .newBubble
        } else if !carriesWords {
            placement = .merge
        } else if speaker != self.speaker || sourceApp != self.sourceApp {
            placement = .newBubble
        } else if shouldBreakParagraph(adding: words, before: text) {
            placement = closedParagraphs + 1 >= TranscriptionConstants.maxParagraphsPerBubble
                ? .newBubble
                : .newParagraph
        } else {
            placement = .merge
        }

        switch placement {
        case .newBubble:
            self.speaker = speaker
            self.sourceApp = sourceApp
            closedParagraphs = 0
            paragraphWords = words
        case .newParagraph:
            closedParagraphs += 1
            paragraphWords = words
        case .merge:
            paragraphWords += words
        }
        didEndSentence = SentenceHeuristics.endsWithSentence(text)
        didEndWithWhitespace = text.last?.isWhitespace ?? false
        didSeeEndpoint = false
        return placement
    }

    /// Whether committing `words` more words should close the current paragraph.
    /// A soft break waits for a sentence end / endpoint once the paragraph passes
    /// `maxWordsPerParagraph`; the hard cap breaks without one, so punctuation-free
    /// speech still gets paragraphed. Neither splits a word.
    private func shouldBreakParagraph(adding words: Int, before text: String) -> Bool {
        let total = paragraphWords + words
        // Last resort — break rather than let a bubble grow without bound (which
        // would also stall the line-count-driven SwiftData flush).
        if total > TranscriptionConstants.paragraphCeilingWords { return true }
        guard isBreakableSeam(before: text) else { return false }
        if total > TranscriptionConstants.maxWordsWithoutSentenceBreak { return true }
        return isAtSafeBreak && total > TranscriptionConstants.maxWordsPerParagraph
    }

    /// Whether a break before `text` would land between words rather than inside one.
    /// True when either side of the seam carries whitespace — which side depends on
    /// the engine (see `didEndWithWhitespace`) — or when the script has no
    /// inter-word spaces (CJK), where any position is a valid break.
    private func isBreakableSeam(before text: String) -> Bool {
        didEndWithWhitespace || !SentenceHeuristics.isWordCharacter(text.first)
    }
}
