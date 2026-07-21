//
//  PostSessionSegmentBuilder.swift
//  OgmoMac
//
//  Groups a flat batch of `PostSessionToken`s (from any post-session engine) into
//  readable, persist-ready lines, reusing the live accumulator's speaker/sentence/
//  word rules via the shared `SentenceHeuristics`. It intentionally uses a SIMPLER
//  grouping than the live path — one paragraph per line, capped at
//  `maxWordsPerParagraph` words — rather than the live accumulator's multi-paragraph
//  bubbles (`\n\n` up to `maxParagraphsPerBubble`). The result is a few more, shorter
//  lines; for a clean batch transcript that reads fine and keeps this builder simple.
//
//  Also unlike the live path there's no source-app attribution (a saved recording is a
//  single mixed stream), so every line's `sourceAppBundleID` stays nil.
//

import Foundation

/// A line ready to persist as a `TranscriptionLine`.
struct RetranscribedLine {
    let text: String
    let speakerId: Int
    let speakerName: String
    let startMs: Int
    let endMs: Int
}

enum PostSessionSegmentBuilder {

    /// Assembles ordered lines from ordered tokens. A line accumulates consecutive
    /// same-speaker sentences up to `maxWordsPerParagraph` words; a speaker change,
    /// or exceeding that cap, starts a new line. A runaway sentence with no
    /// punctuation is force-flushed at `maxAccumulatorWords`.
    static func build(from tokens: [PostSessionToken]) -> [RetranscribedLine] {
        var lines: [RetranscribedLine] = []

        // The line (bubble) currently being assembled.
        var lineText = ""
        var lineWords = 0
        var lineStart = 0
        var lineEnd = 0
        var lineSpeaker = -1
        var lineHasContent = false

        // The in-progress sentence within the current line.
        var sentText = ""
        var sentStart = 0
        var sentEnd = 0
        var sentSpeaker = -1
        var sentHasContent = false

        func flushLine() {
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(RetranscribedLine(
                    text: trimmed,
                    speakerId: lineSpeaker,
                    speakerName: lineSpeaker > 0 ? "Speaker \(lineSpeaker)" : "",
                    startMs: lineStart,
                    endMs: lineEnd
                ))
            }
            lineText = ""
            lineWords = 0
            lineHasContent = false
        }

        func flushSentenceIntoLine() {
            guard sentHasContent else { return }
            let words = SentenceHeuristics.countWords(in: sentText)
            // Close the current line first on a speaker change or when this sentence
            // would overflow the paragraph word cap (mirrors the live accumulator).
            if lineHasContent && (lineSpeaker != sentSpeaker
                || lineWords + words > TranscriptionConstants.maxWordsPerParagraph) {
                flushLine()
            }
            if !lineHasContent {
                lineStart = sentStart
                lineSpeaker = sentSpeaker
                lineHasContent = true
            }
            lineText += sentText
            lineEnd = sentEnd
            lineWords += words
            sentText = ""
            sentHasContent = false
        }

        for token in tokens {
            // A mid-sentence speaker change closes the sentence (it belongs to the
            // old speaker) before this token opens a new one.
            if sentHasContent && token.speaker != sentSpeaker {
                flushSentenceIntoLine()
            }
            if !sentHasContent {
                sentStart = token.startMs
                sentSpeaker = token.speaker
                sentHasContent = true
            }
            sentText += token.text
            sentEnd = token.endMs

            if SentenceHeuristics.endsWithSentence(sentText)
                || SentenceHeuristics.countWords(in: sentText) > TranscriptionConstants.maxAccumulatorWords {
                flushSentenceIntoLine()
            }
        }

        // Tail: commit whatever is left.
        flushSentenceIntoLine()
        flushLine()
        return lines
    }
}
