//
//  FluidAudioEngineConfig.swift
//  OpenCaptions
//
//  Configuration for the on-device FluidAudio transcription engines on macOS:
//  NVIDIA Parakeet TDT v2 (batch model driven in a sliding window) and Nemotron
//  Speech Streaming. Both run via FluidAudio's CoreML managers. English-only; no
//  diarization. See docs/2026-07-10-macos-on-device-engines.md.
//

import FluidAudio
import Foundation

/// Tuning for `NemotronTranscriberService` (FluidAudio `StreamingNemotronAsrManager`).
///
/// Fixed to 560 ms on macOS (the product-selected variant). Nemotron
/// is a true-streaming, cache-aware model that emits punctuation and capitalization
/// natively, so the service flushes each completed sentence to a bubble on punctuation.
struct NemotronEngineConfig {
    /// The streaming chunk size (latency/accuracy trade-off). macOS uses 560 ms.
    let chunkSize: NemotronChunkSize

    init(chunkSize: NemotronChunkSize = .ms560) {
        self.chunkSize = chunkSize
    }
}

/// Tuning for `ParakeetTranscriberService` (FluidAudio `SlidingWindowAsrManager` over
/// the `parakeet-tdt-0.6b-v2` offline transducer — the highest-accuracy English model).
///
/// TDT v2 is a batch model; FluidAudio's `SlidingWindowAsrManager` makes it "stream" by
/// re-encoding an overlapping window on a cadence set by `chunkSeconds`. The library's
/// `.streaming`/`.default` presets use an 11–15 s main chunk (and their advertised
/// `hypothesisChunkSeconds` fast-track is unused in this FluidAudio build), so live text
/// would only refresh every ~11 s — too coarse for live captions. We therefore use a
/// small main chunk for a live-feeling cadence, keeping a long left context for accuracy.
///
/// TUNE `responsiveStreaming` if latency/accuracy needs adjusting. If the built-in
/// sliding-window quality/latency proves inadequate, swap this service's internals for a
/// VoiceInk-style LocalAgreement engine (same `RealtimeTranscriptionEngine` surface) — see
/// the escape-hatch note in the decision doc.
struct ParakeetEngineConfig {
    /// The sliding-window streaming configuration passed to `SlidingWindowAsrManager`.
    let slidingConfig: SlidingWindowAsrConfig

    init(slidingConfig: SlidingWindowAsrConfig = ParakeetEngineConfig.responsiveStreaming) {
        self.slidingConfig = slidingConfig
    }

    /// Responsiveness-tuned config: a 5 s main chunk so confirmed text advances roughly every
    /// ~5 s (first at ~7 s) instead of the preset's ~11–15 s, with 10 s of left context for
    /// encoder accuracy. Trades extra CoreML compute (re-encoding up to ~17 s each tick) for a
    /// more live-feeling transcript; Apple Silicon handles the Parakeet encoder within real time.
    ///
    /// CRITICAL CONSTRAINT — `chunkSeconds + rightContextSeconds >= minContextForConfirmation`.
    /// The manager only promotes volatile→confirmed text once `minContextForConfirmation` seconds
    /// of audio have arrived; any window processed before that stays volatile and is DISCARDED
    /// when the next window replaces it. If `chunkSeconds` is small but `minContext` is large
    /// (e.g. the library's 2–11 s presets paired with minContext 10 s), the first several seconds
    /// of speech are dropped. We keep `minContext == chunkSeconds` so the very first window (center
    /// = [0, chunkSeconds], processed at chunk+right seconds of audio) is already confirmable —
    /// nothing is dropped. Preserve this relationship when tuning `chunkSeconds`.
    static let responsiveStreaming = SlidingWindowAsrConfig(
        chunkSeconds: 5.0,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 10.0,
        rightContextSeconds: 2.0,
        minContextForConfirmation: 5.0,
        confirmationThreshold: 0.85
    )
}
