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
    /// The transcribed text content.
    let text: String
    /// Whether this is a finalized (immutable) result vs. a partial (in-progress) one.
    let isFinal: Bool
    /// Speaker ID (1, 2, 3, …) or -1 when unknown / diarization disabled.
    let speaker: Int
    /// Whether this token marks an endpoint (pause / sentence boundary).
    let isEndpoint: Bool
    /// Session-relative start time in milliseconds (best-effort; may be 0).
    let start_ms: Int
    /// Session-relative end time in milliseconds (best-effort; may be 0).
    let end_ms: Int
}
