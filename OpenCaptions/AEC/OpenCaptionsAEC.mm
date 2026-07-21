//
//  OpenCaptionsAEC.mm
//  OgmoMac
//
//  SpeexDSP-backed implementation of the OgmoAEC bridge (see OgmoAEC.h). Wraps
//  Speex's MDF adaptive echo canceller (`speex_echo_cancellation`) plus its
//  residual-echo preprocessor (`speex_preprocess_run` with the echo state), and
//  re-blocks the arbitrarily-sized mic / reference spans the audio callback
//  delivers into the fixed 10 ms / 160-sample frames Speex requires. Float32
//  in [-1, 1] is converted to/from the int16 Speex works in.
//

#import "OpenCaptionsAEC.h"

#import <cmath>
#import <vector>

#import "speex/speex_echo.h"
#import "speex/speex_preprocess.h"

namespace {

/// 10 ms @ 16 kHz mono — the fixed frame Speex processes.
constexpr int kFrameSamples = 160;

/// Adaptive-filter tail length (samples). Must exceed the round-trip echo delay
/// + room reverberation for the canceller to model it; longer costs CPU and
/// slows convergence. 3200 = 200 ms is a safe default for near-field built-in
/// speaker echo — the primary knob to tune on device if echo leaks through.
constexpr int kFilterTailSamples = 3200;

inline spx_int16_t floatToPCM(float f) {
    float v = f * 32768.0f;
    if (v > 32767.0f) v = 32767.0f;
    if (v < -32768.0f) v = -32768.0f;
    return static_cast<spx_int16_t>(std::lrintf(v));
}

inline float pcmToFloat(spx_int16_t s) { return static_cast<float>(s) * (1.0f / 32768.0f); }

} // namespace

@implementation OgmoAEC {
    SpeexEchoState *_echo;
    SpeexPreprocessState *_preprocess;

    // Carry buffers: leftover (<160) near/far samples awaiting a full frame, and
    // cleaned samples awaiting emission. Both sides receive the same count each
    // callback, so they advance in lockstep and stay frame-aligned.
    std::vector<float> _micAccum;
    std::vector<float> _refAccum;
    std::vector<float> _outAccum;

    // Per-frame int16 scratch (avoids reallocating on the audio thread).
    std::vector<spx_int16_t> _micFrame;
    std::vector<spx_int16_t> _refFrame;
    std::vector<spx_int16_t> _outFrame;

    int _pendingRefDelaySamples; // one-time reference pre-delay from setStreamDelayMs:
    BOOL _delayApplied;
}

- (nullable instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels {
    self = [super init];
    if (!self) return nil;
    if (sampleRate != 16000 || channels != 1) return nil; // unified format only

    _echo = speex_echo_state_init(kFrameSamples, kFilterTailSamples);
    if (!_echo) return nil;
    int rate = sampleRate;
    speex_echo_ctl(_echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);

    _preprocess = speex_preprocess_state_init(kFrameSamples, rate);
    if (!_preprocess) { speex_echo_state_destroy(_echo); _echo = NULL; return nil; }
    // Link the preprocessor to the echo state so it applies residual (nonlinear)
    // echo suppression on top of the linear cancellation — important for the
    // built-in-speaker distortion the linear filter alone can't remove.
    speex_preprocess_ctl(_preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, _echo);

    _micFrame.resize(kFrameSamples);
    _refFrame.resize(kFrameSamples);
    _outFrame.resize(kFrameSamples);
    _pendingRefDelaySamples = 0;
    _delayApplied = NO;
    return self;
}

- (void)dealloc {
    if (_preprocess) speex_preprocess_state_destroy(_preprocess);
    if (_echo) speex_echo_state_destroy(_echo);
}

- (void)setStreamDelayMs:(int)ms {
    if (ms < 0) ms = 0;
    _pendingRefDelaySamples = ms * 16; // 16 samples / ms @ 16 kHz
}

- (void)processReverse:(const float *)reference frameCount:(int)frameCount {
    if (!reference || frameCount <= 0) return;
    // Apply the configured reference pre-delay exactly once, by priming the far
    // side with silence so it "leads" the mic by that many samples.
    if (!_delayApplied) {
        _delayApplied = YES;
        if (_pendingRefDelaySamples > 0) {
            _refAccum.insert(_refAccum.end(), (size_t)_pendingRefDelaySamples, 0.0f);
        }
    }
    _refAccum.insert(_refAccum.end(), reference, reference + frameCount);
}

- (void)process:(const float *)mic into:(float *)out frameCount:(int)frameCount {
    if (!mic || !out || frameCount <= 0) return;
    _micAccum.insert(_micAccum.end(), mic, mic + frameCount);

    // Drain every full 160-sample frame available on BOTH sides.
    while ((int)_micAccum.size() >= kFrameSamples && (int)_refAccum.size() >= kFrameSamples) {
        for (int i = 0; i < kFrameSamples; i++) {
            _micFrame[i] = floatToPCM(_micAccum[i]);
            _refFrame[i] = floatToPCM(_refAccum[i]);
        }
        speex_echo_cancellation(_echo, _micFrame.data(), _refFrame.data(), _outFrame.data());
        speex_preprocess_run(_preprocess, _outFrame.data());
        for (int i = 0; i < kFrameSamples; i++) _outAccum.push_back(pcmToFloat(_outFrame[i]));
        _micAccum.erase(_micAccum.begin(), _micAccum.begin() + kFrameSamples);
        _refAccum.erase(_refAccum.begin(), _refAccum.begin() + kFrameSamples);
    }

    // Emit exactly frameCount cleaned samples (zero-pad only during warm-up,
    // before the first full frame has been produced).
    const int ready = std::min(frameCount, (int)_outAccum.size());
    for (int i = 0; i < ready; i++) out[i] = _outAccum[i];
    for (int i = ready; i < frameCount; i++) out[i] = 0.0f;
    if (ready > 0) _outAccum.erase(_outAccum.begin(), _outAccum.begin() + ready);
}

@end
