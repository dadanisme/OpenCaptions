//
//  SpeakerIdentification.swift
//  OpenCaptions
//
//  The `speakers` half of the summary response: who the model thinks each
//  diarized speaker is. Optional in the summary response schema, so a transcript
//  with no identity signal simply omits it.
//  See docs/2026-07-29-macos-speaker-auto-naming.md.
//

import Foundation

/// One speaker the model was able to name, keyed by the numeric speaker id printed
/// in the transcript it was given (`ConversationFormatter.buildTranscript`).
struct SpeakerIdentification: Decodable {
    let speakerId: Int
    let candidates: [Candidate]?

    /// A possible name for the speaker, with the model's own 0–1 confidence.
    /// `SpeakerNameResolver` — not the model — decides which candidates win.
    struct Candidate: Decodable {
        let name: String
        let confidence: Double
    }
}

/// The `speakers` field, wrapped so that decoding it **cannot throw**.
///
/// This wrapper is the whole reason a garbled prediction can't cost the user their
/// summary. `SummaryAPIResponse` uses the compiler-synthesized decoder, which would
/// call `decodeIfPresent([SpeakerIdentification].self, …)` for a plain array — and
/// that throws on any type mismatch, aborting the decode of `title` / `summary` /
/// `keyPoints` along with it and surfacing as "The summary response was malformed"
/// (`SummaryService+OpenRouterResponse.decodeSummary`). Because `init(from:)` below never
/// throws, a malformed field degrades to "the model named nobody" instead.
struct SpeakerPredictions: Decodable {
    let identifications: [SpeakerIdentification]

    /// Direct construction from already-validated identifications — used by the
    /// Foundation Models transport, whose guided generation guarantees well-typed
    /// values with no decode step, so the lenient-decode protection below doesn't apply.
    init(identifications: [SpeakerIdentification]) {
        self.identifications = identifications
    }

    init(from decoder: Decoder) throws {
        // `try?` absorbs "not an array at all"; `Lenient` absorbs a bad element
        // while keeping its well-formed siblings.
        identifications = ((try? [Lenient](from: decoder)) ?? []).compactMap(\.value)
    }

    /// Decodes a `SpeakerIdentification` or nothing, never an error.
    private struct Lenient: Decodable {
        let value: SpeakerIdentification?

        init(from decoder: Decoder) throws {
            value = try? SpeakerIdentification(from: decoder)
        }
    }
}
