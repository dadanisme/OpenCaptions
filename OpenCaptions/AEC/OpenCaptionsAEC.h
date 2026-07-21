//
//  OpenCaptionsAEC.h
//  OpenCaptions
//
//  Software acoustic echo canceller for the "Microphone + System Audio" mixed
//  source (issue #205, Part C / #208). When you're on a call over the built-in
//  speakers, the mic re-captures the system audio (the other participants), so
//  without cancellation they get transcribed twice. This removes the system
//  audio's speaker-bleed from the mic using the cleanly-captured system audio as
//  the far-end reference, so the others are transcribed once. Headphones never
//  had the bleed; this fixes the built-in-speaker case.
//
//  API is shaped after WebRTC AEC3 (`processReverse` = far-end reference,
//  `process` = near-end mic -> cleaned; both re-blocked to fixed 10 ms frames)
//  so the engine inside can later be swapped from SpeexDSP to a WebRTC AEC3
//  build without touching the call sites. It is currently backed by SpeexDSP's
//  MDF echo canceller + residual-echo preprocessor (pure-C, BSD, vendored in
//  ThirdParty/SpeexDSP).
//
//  Not thread-safe: drive `processReverse:`/`process:into:` from a SINGLE thread
//  (the mic render callback in MixedAudioCaptureService). Samples are Float32
//  normalized to [-1, 1].
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenCaptionsAEC : NSObject

/// Create a canceller for the pipeline's unified format. Returns nil for any
/// unsupported format so the caller can fall back to a plain (no-AEC) mix.
/// @param sampleRate Must be 16000 Hz.
/// @param channels   Must be 1 (mono).
- (nullable instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Feed `frameCount` far-end reference samples (the system audio sent to the
/// speakers). Call once per mic callback, BEFORE `process:into:frameCount:`,
/// with the same count, so the near/far streams stay frame-aligned.
- (void)processReverse:(const float *)reference frameCount:(int)frameCount;

/// Run echo cancellation on `frameCount` near-end mic samples, writing the
/// cleaned result to `out`. `out` MAY alias `mic` (in-place is supported).
/// Always writes exactly `frameCount` samples (zero-padded only during the
/// sub-10 ms warm-up before the first full frame is available).
- (void)process:(const float *)mic into:(float *)out frameCount:(int)frameCount;

/// Alignment knob for the issue's top risk: the mic (AVAudioEngine) and system
/// audio (Core Audio tap) run on independent capture clocks. Delays the far-end
/// reference relative to the mic by `ms` milliseconds (applied once, before the
/// first frame). Default 0 — the mixed pipeline pulls both from the same instant
/// and Speex's adaptive filter absorbs the residual acoustic delay; this is the
/// seam to nudge if on-device testing reveals a systematic offset. Negative
/// values are clamped to 0.
- (void)setStreamDelayMs:(int)ms;

@end

NS_ASSUME_NONNULL_END
