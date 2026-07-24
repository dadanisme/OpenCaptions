//
//  FluidAudioStreamBridge.swift
//  OpenCaptions
//
//  Stateless helpers that bridge FluidAudio's streaming managers to the engine-agnostic
//  `TranscriptionToken` pipeline. `makeBuffer(from:)` wraps the app's 16 kHz Float32 PCM
//  chunks for FluidAudio; `tokens(forFull:confirmedPrefix:)` diffs the full accumulated
//  transcript Nemotron reports on each partial callback into (finals, partials).
//
//  Nemotron uses the
//  full-transcript diff below; Parakeet (SlidingWindow) reuses only `makeBuffer(from:)`
//  and does its own confirmed/volatile mapping (see `ParakeetTranscriberService`).
//

import AVFoundation
import Foundation

enum FluidAudioStreamBridge {

    /// Words of un-finalized tail kept live when the safety net promotes a long punctuation-free run.
    private static let keepTailWords = 8

    // MARK: - Audio

    /// Wraps a chunk of 16 kHz mono Float32 PCM (`Data`, as produced by `MacAudioService`) in an
    /// `AVAudioPCMBuffer` for the FluidAudio managers. FluidAudio resamples internally, so the
    /// 16 kHz format is a no-op pass-through. Returns nil for empty / malformed input.
    static func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Float>.size
        guard frameCount > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let channel = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Float.self).baseAddress {
                channel[0].update(from: base, count: frameCount)
            }
        }
        return buffer
    }

    // MARK: - Transcript → Tokens

    /// Translates a FluidAudio full-transcript update into `(finals, partials)` and advances
    /// `confirmedPrefix` to mark what was emitted as finals:
    ///
    /// 1. Each completed sentence (ending at a `.`/`!`/`?`) becomes a **final** — the ViewModel
    ///    flushes it into a bubble on the punctuation (Nemotron's native punctuation).
    /// 2. If the remaining tail grows past `maxAccumulatorWords` without punctuation, a
    ///    word-bounded prefix is promoted to a **final** so the partial stays bounded.
    /// 3. Whatever remains is the live **partial**.
    ///
    /// Mutated `confirmedPrefix` is always advanced by byte-exact substrings of `full`, so the
    /// append-only `delta` diff keeps matching across callbacks.
    static func tokens(
        forFull full: String, confirmedPrefix: inout String
    ) -> (finals: [TranscriptionToken], partials: [TranscriptionToken]) {
        let newText = delta(of: full, after: confirmedPrefix)
        guard !newText.isEmpty else { return ([], []) }

        var finals: [TranscriptionToken] = []

        let (sentences, afterSentences) = splitSentences(newText)
        for sentence in sentences where !sentence.isEmpty {
            finals.append(token(text: sentence, isFinal: true))
            confirmedPrefix += sentence
        }

        var tail = afterSentences
        let (promoted, liveTail) = promoteIfTooLong(
            tail, maxWords: TranscriptionConstants.maxAccumulatorWords)
        if !promoted.isEmpty {
            finals.append(token(text: promoted, isFinal: true))
            confirmedPrefix += promoted
            tail = liveTail
        }

        let partials = tail.isEmpty ? [] : [token(text: tail, isFinal: false)]
        return (finals, partials)
    }

    /// Builds an engine token with the on-device defaults (no diarization, no timestamps).
    /// Shared with `ParakeetTranscriberService`, which maps its own confirmed/volatile text.
    static func token(text: String, isFinal: Bool) -> TranscriptionToken {
        // speaker -1 (no diarization); timestamps unused (providesReliableTimestamps == false,
        // so the ViewModel stamps bubbles from its own clock).
        TranscriptionToken(
            text: text, isFinal: isFinal, speaker: -1,
            isEndpoint: false, start_ms: 0, end_ms: 0
        )
    }

    // MARK: - Helpers

    /// The newly-appended suffix of `full` beyond what was already emitted (`prefix`). Relies on
    /// FluidAudio's append-only guarantee; returns "" if `full` ever diverges from `prefix`.
    private static func delta(of full: String, after prefix: String) -> String {
        guard !prefix.isEmpty else { return full }
        guard full.hasPrefix(prefix) else { return "" }
        return String(full.dropFirst(prefix.count))
    }

    /// Splits text into each complete sentence (ending at a terminator, plus any trailing closing
    /// quote) and the incomplete remainder. Returns exact substrings (no re-joining).
    private static func splitSentences(_ text: String) -> (sentences: [String], tail: String) {
        let enders: Set<Character> = [".", "!", "?"]
        let closingQuotes: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}"]

        var sentences: [String] = []
        var segmentStart = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if enders.contains(text[i]) {
                var end = text.index(after: i)
                if end < text.endIndex, closingQuotes.contains(text[end]) {
                    end = text.index(after: end)
                }
                sentences.append(String(text[segmentStart..<end]))
                segmentStart = end
                i = end
                continue
            }
            i = text.index(after: i)
        }
        return (sentences, String(text[segmentStart...]))
    }

    /// If `text` exceeds `maxWords`, returns a word-bounded prefix to promote (keeping the last
    /// `keepTailWords` words live) and the remaining tail; otherwise ("", text). Exact substrings.
    private static func promoteIfTooLong(
        _ text: String, maxWords: Int
    ) -> (promote: String, tail: String) {
        var wordStarts: [String.Index] = []
        var prevWasSpace = true
        var i = text.startIndex
        while i < text.endIndex {
            let isSpace = text[i].isWhitespace
            if !isSpace, prevWasSpace { wordStarts.append(i) }
            prevWasSpace = isSpace
            i = text.index(after: i)
        }

        guard wordStarts.count > maxWords else { return ("", text) }
        let cutWordIndex = wordStarts.count - keepTailWords
        guard cutWordIndex > 0, cutWordIndex < wordStarts.count else { return ("", text) }
        let cut = wordStarts[cutWordIndex]
        return (String(text[text.startIndex..<cut]), String(text[cut...]))
    }
}
