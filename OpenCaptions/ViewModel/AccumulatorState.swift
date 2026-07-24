//
//  AccumulatorState.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 20/10/25.
//

import Foundation

/// Holds state for the text accumulator that buffers same-speaker tokens
/// before committing them to a bubble.
struct AccumulatorState {
    // MARK: - Sentence buffer (resets on each sentence flush)

    var text: String = ""
    var speaker: Int = -1
    var startMs: Int = 0
    var endMs: Int = 0

    // MARK: - Bubble tracking (persists across sentence flushes, resets on speaker change or new bubble)

    /// Words in the current paragraph of the current bubble
    var bubbleWordCount: Int = 0

    /// Paragraphs in the current bubble
    var bubbleParagraphCount: Int = 0

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Resets only the sentence buffer, keeps bubble tracking
    mutating func resetSentence() {
        text = ""
        startMs = 0
        endMs = 0
    }

    /// Full reset — new speaker or new bubble
    mutating func reset() {
        self = AccumulatorState()
    }
}
