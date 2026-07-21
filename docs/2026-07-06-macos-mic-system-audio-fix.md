# macOS Mic + System-Audio Fix: VPIO Removal, Process Taps, Software AEC — #205

**Date:** 2026-07-06 · **Target:** OpenCaptions · **Epic:** #103 · **Supersedes parts of:** #176 (SCK system audio), #189 (VPIO mix)

## Problem

The **Microphone + System Audio** mixed source (`MixedAudioCaptureService`, #189) was product-breaking in three ways:

1. **Mic monopoly** — while a mixed session ran, other apps (Zoom/Meet/Voice Memos) got no mic input, breaking the exact scenario the mode exists for.
2. **Can't switch out of mixed mode mid-session** — Mixed → Microphone-only *ended* the transcription instead of hot-swapping.
3. **Over-broad permission** — we requested full **Screen Recording** even though macOS now offers a narrower **audio-only** recording grant.

## Root causes (researched, verified)

- **Issues 1 & 2 share one cause: VPIO.** `AVAudioInputNode.setVoiceProcessingEnabled(true)` on macOS does **not** literally hog the mic (input devices are multi-client at the HAL level; `kAudioDevicePropertyHogMode` is a separate opt-in VPIO never engages). Instead it builds a **private aggregate device (AUVPAggregate)** wrapping input+output for the AEC reference, and in doing so **reconfigures the shared input device** (format/sample-rate churn, prefers the default/built-in device, gain changes). That reconfiguration is what perturbs other apps' mic access (**issue 1**). Separately, `setVoiceProcessingEnabled` is synchronous and *itself* fires an `AVAudioEngineConfigurationChange`, and tearing the aggregate down on a source swap is a topology change that lands on the freshly-started replacement mic engine → the config-change observer calls `failSession` (**issue 2**). Plain mic↔system switching already worked; only paths through VPIO broke.
- **Issue 3.** An audio-only `SCStream` (`capturesAudio = true`, tiny video) **still requires the full Screen Recording TCC grant** on macOS 14/15/26 — ScreenCaptureKit has no audio-only permission tier and no entitlement. The only API that grants the narrow **Audio Capture** permission (`kTCCServiceAudioCapture` / `NSAudioCaptureUsageDescription`) is **Core Audio process taps** (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.2+, reliable 14.4+), which need no Screen Recording grant.

Sources: Apple docs (`setVoiceProcessingEnabled`, ScreenCaptureKit "Capturing screen content", CoreAudio "Capturing system audio with Core Audio taps"), WWDC23 s10235, Apple Developer Forums (#128518, #825780), `insidegui/AudioCap`, dgrlabs "Capturing System Audio on macOS in 2026".

## Decisions

- **Drop VPIO.** There is no non-seizing Apple AEC (standalone AUVoiceIO uses the same aggregate machinery). Use a **plain multi-client mic engine** and cancel echo in **software** instead. This is the load-bearing reversal of #189's VPIO decision.
- **Issue 3 → Core Audio process taps, raise the deployment target 14.0 → 14.4** (one clean path, no SCK fallback; the 14.0–14.3 band is dropped — in mid-2026 nearly all users are on 15/26).
- **Echo → software AEC (WebRTC AEC3 / audio_processing module)**, fed the captured system audio as the far-end reference.

## Approach — three sequenced PRs

### Part A — Remove VPIO (fixes issues 1 & 2) — **implemented**

`MixedAudioCaptureService+Mic.configureMicEngine()` no longer enables voice processing, the other-audio-ducking config, or AGC. It installs a plain input tap on `input.inputFormat(forBus: 0)` — the mic is now a plain multi-client engine identical in spirit to `MacAudioService`, so it coexists with other apps (issue 1) and hot-swaps cleanly without tripping the config-change → `failSession` path (issue 2). The mic-as-pacer + `AudioRingBuffer` software mix is unchanged.

**Interim tradeoff:** with VPIO gone and software AEC not yet landed (Part C), the mic's speaker-bleed of the system audio is uncancelled — on **built-in speakers** the system audio can echo into the transcript; **headphones eliminate it**. A source-selector tooltip nudges toward headphones in Mixed mode (removed once Part C lands). This is strictly better than before (mixed mode was unusable).

### Part B — Process taps for system audio (fixes issue 3) — **implemented**

**Sandbox spike passed first.** A throwaway probe in a signed, sandboxed build (global tap + private aggregate + `AudioDeviceStart`) captured audio (48 kHz mono, non-zero) with the existing `com.apple.security.device.audio-input` entitlement — confirming process taps work under the App Sandbox before committing the port.

`SystemAudioTapCaptureService` (`+IO`, `+Listeners`) + `CoreAudioTapUtils` replace the ScreenCaptureKit `SystemAudioCaptureService` (deleted), producing the identical 16 kHz mono Float32 `AudioFrame`s so the mixed source and the pipeline are unchanged. It builds a whole-system mono tap (excluding our own process) + a private auto-started aggregate wrapping the default output, installs an IOProc, converts to 16 kHz mono, and tears down in order (device → IOProc → aggregate → tap). A default-output-device property listener surfaces device changes as an interruption (the `SCStreamDelegate.didStopWithError` equivalent), failing the session while keeping the transcript.

- **Permission** now uses the narrow **"Audio Recording"** grant (`NSAudioCaptureUsageDescription` added to `OpenCaptions-Info.plist`); the old Screen Recording gate, "needs relaunch" state, and screen-access alert are gone. Process taps have **no public preflight/request API**, so system-audio sources start optimistically — the OS prompts on the first `AudioDeviceStart`. Only the microphone (public preflight) is gated before capture; `MacAudioPermissionView` now handles just `.micDenied`.
- **Deployment target** bumped `14.0 → 14.4` (both OpenCaptions configs) — the floor for the process-tap global-exclude initializers and the reliable TCC category.
- **Known limitation / follow-up:** because there's no preflight, an outright audio-capture *denial* isn't surfaced with a guidance screen (the session just gets no system audio). A silence watchdog that hints at System Settings after N seconds of pure silence is a possible follow-up.

### Part C — software AEC — **implemented (SpeexDSP; #208)**

Echo is cancelled in software with an Objective-C++ bridge, `OpenCaptionsAEC` (`OpenCaptions/AEC/OpenCaptionsAEC.h`/`.mm`), inserted into `MixedAudioCaptureService` between the ring read and the sum: the mixer now yields `AEC(mic, reference: system) + system` = the user's voice (echo removed) + the remote participants, each once. Built-in speakers no longer double the other side; headphones (never affected) are unchanged. The interim "use headphones in Mixed mode" tooltip on the source selector is removed.

**Engine decision — SpeexDSP, not WebRTC AEC3 (the planned primary).** The primary plan was to build WebRTC's `audio_processing` / AEC3 module from source into a macOS `.xcframework` (the public `stasel/WebRTC` is 300–400 MB and doesn't expose AEC3). That build is heavy and fragile — it needs a Chromium/`gn`/`ninja` (or `meson`) toolchain, produces an App-Store-bound binary that can't be verified without on-device DSP tuning, and the Xcode `binaryTarget` wiring is manual. We took the issue's explicit **contingency instead: SpeexDSP's MDF echo canceller** (`speex_echo_cancellation`) + residual-echo preprocessor (`speex_preprocess_run`). It's pure C (BSD-3), so a **six-file source subset** is vendored under `OpenCaptions/ThirdParty/SpeexDSP/` and compiled directly into the target — **no binary to build/host/sign, no SPM dependency**. It's weaker than AEC3 but ships now and is the greenlit fallback.

**WebRTC-swappable.** `OpenCaptionsAEC`'s Swift-facing API is deliberately AEC3-shaped — `init(sampleRate:channels:)`, `processReverse(_:frameCount:)` (system reference), `process(_:into:frameCount:)` (mic → cleaned, in-place OK), `setStreamDelayMs(_:)` — and re-blocks both streams to fixed **160-sample / 10 ms @ 16 kHz mono** frames internally. So a future WebRTC AEC3 engine can replace the Speex internals of `OpenCaptionsAEC.mm` without touching `MixedAudioCaptureService`. Speex works in int16; the bridge converts to/from the pipeline's Float32 `[-1, 1]`.

**Validation.** The vendored sources + the `.mm` bridge were compiled and linked with Xcode's exact clang toolchain (arm64, macOS 14.4 min, `gnu17`/`gnu++20`, `HAVE_CONFIG_H`) and run through a functional harness: a pure-echo signal (mic = reference) converges to **~65–70 dB** echo reduction, arbitrary non-160-multiple callback sizes re-block correctly, and in-place output works. Config (`OpenCaptions/ThirdParty/SpeexDSP/src/config.h`): `FLOATING_POINT`, `USE_KISS_FFT`, `EXPORT` away.

**Top risk (unchanged) & tuning knobs.** The mic (`AVAudioEngine`) and system audio (process tap) are independent capture clocks; the existing `AudioRingBuffer` (drop-oldest) already absorbs that drift *before* the AEC, and Speex's adaptive filter absorbs the residual acoustic delay. The on-device tuning seams are `OpenCaptionsAEC.setStreamDelayMs(_:)` (reference-vs-mic alignment, default 0) and `kFilterTailSamples` in `OpenCaptionsAEC.mm` (adaptive-filter tail; default 3200 = 200 ms). Long-session AEC stability on built-in speakers is the remaining on-device check (see below).

## On-device verification

- **A:** Mixed mode → other apps regain mic input; switch Mixed↔Mic↔System in every direction with the transcript + socket preserved.
- **B (signed, sandboxed):** prompt is Audio Capture; system transcript flows; concurrent mic engine unaffected; output-device change handled.
- **C:** system audio transcribed once (not doubled) on built-in speakers; long-session AEC stability. Confirm the canceller is actually engaged (not a silent plain-sum fall-back) via the once-per-session `OpenCaptionsAEC ready` log — Console.app, subsystem `com.muhammadramdan.OpenCaptions`, category `MixedAudio`. Verified in a real Discord meeting on built-in speakers (no headphones): clean, single transcript with the log confirming `ready`.

All must be validated on a **stably-signed** build (dev signing forgets TCC each launch). The user builds the OpenCaptions scheme in Xcode. CI: `scripts/check-file-length.sh OpenCaptions`.
