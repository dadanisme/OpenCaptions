//
//  RealtimeTranscriptionEngine.swift
//  OpenCaptions
//
//  Production-side abstraction over real-time (streaming) speech-to-text engines.
//

import Foundation

// MARK: - Engine Capabilities

/// Static traits of a transcription engine that the ViewModel needs to adapt its
/// pipeline to (timestamp handling, reset cadence, diarization availability, analytics).
struct EngineCapabilities {
    /// Stable, locale-independent identifier used for analytics grouping (e.g. "soniox", "gladia").
    let engineId: String
    /// Human-readable name for debug/settings UI.
    let displayName: String
    /// Whether this engine can produce per-speaker diarization labels.
    let supportsDiarization: Bool
    /// Whether the engine's per-token timestamps are reliable. When false, the ViewModel
    /// stamps bubbles from its own `totalActiveTime` clock instead.
    let providesReliableTimestamps: Bool
    /// Whether the engine emits explicit endpoint tokens (Soniox `<end>`). When false the
    /// ViewModel relies on trailing punctuation to flush sentences.
    let emitsEndpointTokens: Bool
    /// Upper bound, in seconds, on a single backend session before the ViewModel must
    /// hot-swap to a fresh connection (covers provider session caps and token expiry).
    let maxSessionSeconds: TimeInterval
    /// Whether `connectAndStart()` does heavy local work (e.g. loading an on-device model) worth
    /// showing a loading indicator for. Cloud engines connect near-instantly and set this false.
    let requiresPreparation: Bool
}

// MARK: - Protocol

/// A real-time, streaming transcription engine.
///
/// This mirrors the callback + lifecycle surface that `OnlineViewModel` already drives, so
/// any conforming engine (Soniox, Gladia, …) is interchangeable behind the same ViewModel
/// pipeline (per-token line building → bubble grouping → SwiftData flush → Firestore sync).
///
/// Intentionally **not** `@MainActor`-isolated: the concrete clients are plain
/// `URLSessionWebSocketTask` wrappers and the ViewModel hops to the main actor in its
/// callbacks, matching the existing `OnlineTranscriberService` behaviour.
protocol RealtimeTranscriptionEngine: AnyObject {

    /// Static traits used by the ViewModel to adapt its pipeline.
    var capabilities: EngineCapabilities { get }

    // MARK: Callbacks

    /// Invoked when new tokens arrive.
    /// - Parameters:
    ///   - finals: finalized (immutable) tokens
    ///   - partial: partial (in-progress) tokens
    var onTokens: ((_ finals: [TranscriptionToken], _ partial: [TranscriptionToken]) -> Void)? { get set }
    var onError: ((TranscriptionServiceError) -> Void)? { get set }
    var onConnectionStateChange: ((ConnectionState) -> Void)? { get set }

    // MARK: Lifecycle

    /// Establish the connection and send any initial configuration.
    func connectAndStart() async throws
    /// Send a chunk of raw audio. Input is 16 kHz mono Float32 PCM; the engine converts
    /// to its own wire format as needed.
    func sendAudioChunk(_ data: Data)
    /// Signal end-of-audio and request final results.
    func finalize()
    /// Close the connection and release resources.
    func close()

    // MARK: Connection health

    /// Begin keepalive (used while paused so the socket doesn't time out). May be a no-op.
    func startKeepalive()
    func stopKeepalive()
    /// Begin "audio in, but no tokens out" zombie-connection detection. May be a no-op.
    func startZombieCheck()
    func stopZombieCheck()
    /// Report the current audio RMS level so the engine can gate zombie detection.
    func reportAudioLevel(_ level: Float)
    /// Mark that tokens were just received (resets zombie timers).
    func markTokensReceived()

    /// Set when the connection died and must be replaced on resume.
    var needsReconnect: Bool { get }
}
