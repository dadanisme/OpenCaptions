//
//  TranscriptionConstants.swift
//  OpenCaptions
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

    /// Soft target for words per paragraph within a bubble. Once a paragraph passes
    /// this, the live builder breaks at the next sentence end / engine endpoint.
    static let maxWordsPerParagraph = 50

    /// Maximum paragraphs per bubble before splitting to new bubble
    static let maxParagraphsPerBubble = 3

    /// Hard cap on words run without a sentence break. The live builder breaks a
    /// paragraph here even with no punctuation in sight (at a non-word-splitting
    /// boundary), and the batch `PostSessionSegmentBuilder` closes a runaway
    /// sentence at the same count — runaway safety for punctuation-free speech.
    static let maxWordsWithoutSentenceBreak = 100

    /// Absolute ceiling on paragraph length for the live builder. The cap above only
    /// breaks at a boundary that won't split a word; this one breaks regardless.
    /// Only reachable if an engine never emits a breakable token boundary — a
    /// mid-word break is still better than a bubble that grows without bound, which
    /// would also stall the line-count-driven SwiftData flush.
    static let paragraphCeilingWords = 200

    // MARK: - Connection Health

    /// Interval in seconds between periodic Soniox connection resets.
    /// Temporarily set to 5 hours to evaluate whether the workaround is still needed.
    static let connectionResetIntervalSeconds: TimeInterval = 18000

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
