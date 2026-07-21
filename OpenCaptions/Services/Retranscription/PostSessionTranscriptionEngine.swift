//
//  PostSessionTranscriptionEngine.swift
//  OgmoMac
//
//  The pluggable PROTOCOL for re-transcribing a completed session's saved audio
//  for improved accuracy. It mirrors the live `RealtimeTranscriptionEngine`
//  platform, but is one-shot/batch: instead of streaming chunks and emitting
//  incremental tokens, it takes a finished audio file and returns the full ordered
//  token list in a single async call. Concrete engines:
//    • `ParakeetPostSessionEngine` — on-device FluidAudio Parakeet TDT v2 (offline, free, English-only, no diarization)
//    • `SonioxAsyncPostSessionEngine` — cloud Soniox `stt-async-v5` (diarized, billable)
//
//  Adding a provider = add a `PostSessionTranscriptionEngine` conformer and a
//  `RetranscriptionEngineKind` case. See issue #245 and
//  docs/2026-07-16-macos-post-session-retranscription.md.
//

import Foundation

// MARK: - Token

/// One recognized word with timing and an optional speaker — engine-agnostic,
/// mirroring the live `TranscriptionToken` but reduced to what a batch pass yields.
/// `text` carries a leading space between words (the Soniox convention), so the
/// segment builder concatenates tokens verbatim and trims per line.
struct PostSessionToken {
    let text: String
    /// Diarization id (1, 2, …) or `-1` when the engine doesn't separate speakers.
    let speaker: Int
    /// Session-relative start/end in milliseconds, aligned to the saved recording
    /// (which is the exact stream that was transcribed), so line timestamps drive
    /// the playback playhead exactly like a live session.
    let startMs: Int
    let endMs: Int
}

// MARK: - Progress

/// A progress update from a running re-transcription, rendered by the overlay.
struct PostSessionProgress: Equatable {
    enum Stage: Equatable {
        case preparing      // loading the on-device model / connecting
        case uploading      // sending audio to a cloud provider
        case transcribing   // decoding audio → text
        case downloading    // fetching the cloud transcript
        case finalizing     // writing lines + regenerating the summary
    }
    let stage: Stage
    /// Completion in `0...1` when the engine can report it; `nil` = indeterminate.
    let fraction: Double?

    init(stage: Stage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

// MARK: - Capabilities

/// Static traits of a post-session engine, mirroring the live `EngineCapabilities`.
struct PostSessionEngineCapabilities {
    /// Stable id for analytics / persistence (e.g. "parakeet_async", "soniox_async").
    let engineId: String
    /// Human-readable name shown in the menu / overlay.
    let displayName: String
    /// Whether this engine returns per-speaker labels (else every token is speaker -1).
    let supportsDiarization: Bool
    /// On-device (free, no upload) vs. cloud (billable, uploads audio).
    let isOnDevice: Bool
}

// MARK: - Errors

/// Failures surfaced to the re-transcription UI.
enum PostSessionEngineError: LocalizedError {
    /// The session has no saved recording to re-transcribe.
    case audioUnavailable
    /// The on-device model isn't downloaded yet.
    case modelNotDownloaded
    /// The engine produced no speech.
    case emptyResult
    /// A networking / transport failure (cloud engines).
    case network(String)
    /// The provider reported a failure (cloud engines).
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            return "This session has no saved recording to re-transcribe."
        case .modelNotDownloaded:
            return "The offline model isn't downloaded yet. Download it from Settings → General → Offline Mode, then try again."
        case .emptyResult:
            return "No speech was found in the recording."
        case .network(let message):
            return "Network error: \(message)"
        case .provider(let message):
            return "Transcription failed: \(message)"
        }
    }
}

// MARK: - Protocol

/// A pluggable engine that re-transcribes a complete recording in one batch pass.
protocol PostSessionTranscriptionEngine: AnyObject {

    /// Static traits (diarization, on-device vs. cloud, display name).
    var capabilities: PostSessionEngineCapabilities { get }

    /// Transcribes `audioURL` end to end and returns the full ordered token list.
    ///
    /// Implementations MUST honor cooperative cancellation (call
    /// `Task.checkCancellation()` around long/awaited work and release resources on
    /// throw) and report coarse progress via `progress`, which is main-actor isolated
    /// so it can drive `@Observable` UI state directly.
    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken]
}
