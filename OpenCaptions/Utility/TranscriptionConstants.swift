//
//  TranscriptionConstants.swift
//  unmute
//

import Foundation

enum TranscriptionConstants {
    // MARK: - Memory Window

    /// Maximum lines kept in-memory in TranscriberModel
    static let hotWindowSize = 50

    /// When array count exceeds this, flush oldest lines to SwiftData
    static let flushThreshold = 70

    /// Number of oldest lines to flush at once
    static let flushBatchSize = 20

    /// Lines loaded per batch when scrolling into flushed region
    static let scrollLoadBatchSize = 30

    /// LRU cache capacity for recently-viewed flushed lines
    static let lruCacheSize = 50

    // MARK: - Bubble Grouping

    /// Maximum words per paragraph within a bubble
    static let maxWordsPerParagraph = 50

    /// Maximum paragraphs per bubble before splitting to new bubble
    static let maxParagraphsPerBubble = 3

    /// Diarization-off streaming: soft paragraph target in characters (~maxWordsPerParagraph
    /// of English). Once a paragraph passes this it breaks at the next sentence end.
    /// Char-based so it also bounds scripts without inter-word spaces (e.g. zh-Hans),
    /// where whitespace word counts stay ~1.
    static let maxCharsPerParagraph = 300

    /// Diarization-off streaming: hard paragraph cap in characters (~maxAccumulatorWords of
    /// English). Breaks at the next safe (non-word-splitting) boundary even without
    /// sentence punctuation — runaway safety for punctuation-free speech.
    static let maxStreamingParagraphChars = 600

    // MARK: - Connection Health

    /// Interval in seconds between periodic Soniox connection resets.
    /// Temporarily set to 5 hours to evaluate whether the workaround is still needed (issue #104).
    static let connectionResetIntervalSeconds: TimeInterval = 18000

    /// Max words allowed in the accumulator before force-flushing without punctuation.
    /// Safety net: if Soniox stops sending punctuation, prevents unbounded partial bubble growth.
    static let maxAccumulatorWords = 100

    // MARK: - WebSocket Reconnect

    /// Max auto-reconnect attempts before showing manual retry
    static let reconnectMaxAttempts = 3

    /// Exponential backoff durations in seconds
    static let reconnectBackoffSeconds: [TimeInterval] = [2, 4, 8]

    // MARK: - Circuit Breaker

    /// Max reconnections allowed within the sliding window before tripping the circuit breaker
    static let circuitBreakerMaxReconnects = 4

    /// Sliding window duration in seconds for the circuit breaker
    static let circuitBreakerWindowSeconds: TimeInterval = 120

    /// Cooldown in seconds after a reconnection before allowing periodic hot-swap resets
    static let postReconnectResetCooldownSeconds: TimeInterval = 30

    // MARK: - Zombie Detection

    /// Normalized audio level threshold for "someone is speaking"
    /// Raw RMS ~0.008 → normalized 0.2 (via rms * 25.0)
    static let zombieAudioLevelThreshold: Float = 0.2

    /// Seconds of speech-level audio with zero tokens before zombie alarm
    static let zombieTimeoutSeconds: TimeInterval = 30

    // MARK: - Soniox API

    /// Whether to enable strict language restriction for Soniox transcription.
    /// When true, Soniox strongly prefers output only in the specified language hints.
    /// Best with a single language; accuracy degrades with multiple hints.
    /// Default: false (hints are soft preferences only).
    static let isLanguageHintsStrict: Bool = false
}
