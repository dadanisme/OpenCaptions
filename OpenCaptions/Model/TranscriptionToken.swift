//
//  TranscriptionToken.swift
//  OpenCaptions
//
//  Engine-agnostic transcription token emitted by any RealtimeTranscriptionEngine.
//

import Foundation

/// A single streaming transcription token, normalized across engines (Soniox, Gladia, …).
///
/// Field names mirror the original `OnlineTranscriberService.Token` so the existing
/// `OnlineViewModel` token-processing pipeline consumes it unchanged.
struct TranscriptionToken {

    /// Speaker ID meaning "diarization unavailable" — a single-stream on-device
    /// engine, or a token Soniox couldn't attribute. This is its ONLY meaning: the
    /// live line builder tracks "no bubble open yet" with an optional
    /// (`LiveLineCursor.speaker`) rather than overloading this value.
    static let unknownSpeaker = -1

    /// The transcribed text content.
    let text: String
    /// Whether this is a finalized (immutable) result vs. a partial (in-progress) one.
    let isFinal: Bool
    /// Speaker ID (1, 2, 3, …) or `unknownSpeaker` when diarization is unavailable.
    let speaker: Int
    /// Whether this token marks an endpoint (pause / sentence boundary).
    let isEndpoint: Bool
    /// Session-relative start time in milliseconds (best-effort; may be 0).
    let start_ms: Int
    /// Session-relative end time in milliseconds (best-effort; may be 0).
    let end_ms: Int
}
