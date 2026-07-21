# macOS Mic + System-Audio Mix with Echo Cancellation (VPIO)

**Date:** 2026-07-05 · **Target:** OpenCaptions · **Depends on:** Phase 1

## Problem

Phase 1 shipped microphone **or** whole-system audio as a live-switchable source. Phase 2 adds the third option — **Microphone + System Audio mixed** into one transcript — so a user on a video call is transcribed alongside the other participants. The naïve mix doubles the system audio: ScreenCaptureKit (SCK) captures the other apps' audio cleanly, *and* the mic re-captures the same audio bleeding from the speakers. The fix is acoustic echo cancellation on the mic so only the user's voice survives from the mic path.

## Approach

Extends the Phase-1 abstraction — **one new enum case + one new service**, no rewrite:

- `AudioSource.microphoneAndSystem` (the transport-pill iterates `allCases`, so it appears automatically) → `MixedAudioCaptureService` via `AudioCaptureSourceFactory`.
- `MixedAudioCaptureService: AudioCaptureSource` composes:
  - a **VPIO-enabled** mic engine (`AVAudioEngine` input node, `setVoiceProcessingEnabled(true)`), and
  - the existing Phase-1 `SystemAudioCaptureService` (SCK), reused as-is.
- Both emit the identical 16 kHz / mono / Float32 `AudioFrame`, so `MacTranscriptionViewModel`'s chunking / Soniox-send / pause-resume machinery stays source-agnostic.

## Echo cancellation (VPIO — no third-party lib)

`AVAudioInputNode.setVoiceProcessingEnabled(true)` runs Apple's AEC. On **macOS** the AEC reference is the **hardware output mix, including other apps' audio** (verified against a shipping mic+SCK transcription app), so the mic's speaker-bleed of the system audio is cancelled with no custom reference signal and no third-party library. The clean SCK copy is then summed back in software.

Required gotchas, all handled in `MixedAudioCaptureService+Mic`:

- **Disable advanced ducking** — otherwise VPIO attenuates the SCK-captured system audio: `input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)` (macOS 14+; deployment target is 14.0).
- **Multi-channel VP input format** — after enabling VPIO the mic input format can become multi-channel (9 channels reported). We read the tap format **after** enabling VPIO, **extract channel 0** into a mono buffer, and build the resampler lazily from the *live* buffer sample rate (rebuilt if it changes) — never reusing a stale mono converter (the documented crash).
- **Disable AGC** — `input.isVoiceProcessingAGCEnabled = false`. AGC's silence-gain ramps would pump residual echo and fight the fixed-sum mix; mic level is left to the hardware input gain. (Trade-off: quiet voices aren't auto-boosted; a future tuning knob if needed.)

## Software mixing

- SCK audio is mixed **in software only** — never routed through the engine's output node (that would replay to the speakers and re-double the room audio).
- The **mic tap is the pacer.** The mic input node produces continuous 16 kHz frames regardless of speech, so it defines the output clock. Per callback: extract ch0 → resample to 16 kHz mono → pull an equal-length span of system audio → sum sample-wise → clamp to `[-1, 1]` → yield.
- Only the **asynchronous SCK stream** is buffered, in a single bounded `AudioRingBuffer` (~500 ms / 8000 samples). This is a deliberate simplification of the initial "two ring buffers" sketch: the mic doesn't need buffering because it *is* the pump; only SCK needs realigning to the mic clock. **Drop-oldest** on overflow discards stale system audio (absorbing the mic-vs-SCK clock drift); an **underrun zero-pads** (that slice is mic-only for a few ms). In steady state both run at 16 kHz real-time, so consumption ≈ production and the ring hovers near one callback's worth — no systematic loss.
- The ring is the one genuine cross-thread structure (SCK sample queue writes, mic render thread reads), so it is `NSLock`-guarded. This is stricter than the Phase-1 continuation/converter sharing (which the Phase-1 doc left un-hardened) because concurrent index mutation would corrupt, not just tear.

## Permissions

The mixed source needs **both** the Microphone grant and the Screen & System Audio Recording grant. `AudioSource` gains `requiresMicrophone` alongside `requiresScreenRecording`:

- `startIfPermitted()` requests **mic first** (a quick prompt, no relaunch), then screen recording (whose macOS-14 first-grant "needs relaunch" state is unchanged). Denials surface via the existing `MacAudioPermissionView` states (`micDenied` / `screenDenied` / `needsRelaunch`) — no new UI.
- The mid-session live switch (`handleSourceSelection`) gates screen recording synchronously, then requests mic in a `Task` before applying the swap; on a mic denial the picker reverts. This also closes a latent Phase-1 gap where switching to plain Microphone from a system-audio-only session never re-checked mic access.

## Lifecycle

`start()` starts SCK first (its async setup can throw on a permission miss), begins draining into the ring, then starts the mic pacer last (so the consumer sees mixed frames immediately). Every error / stop / race path funnels through one idempotent `teardownAll()`. Like the Phase-1 SCK source, a `stopRequested` flag is set by `stop()` even before `isRunning` flips and is re-checked after each async step in `start()`, so a Stop (or a socket drop → `failSession`) that races SCK's multi-hundred-ms setup still tears both halves down instead of orphaning a live mic + SCStream (privacy indicators lit) with nothing left to stop it. `pause()` pauses the mic engine (no pacer → no frames) and soft-pauses SCK; the drain task survives pause and is only cancelled by `stop()`. `resume()` first resets the ring (dropping stale pre-pause system audio that would otherwise mix into the first resumed frames), then rethrows if either half won't restart so `MacTranscriptionViewModel` can `failSession` while keeping the transcript. Mid-session interruptions (mic device/route change via `AVAudioEngineConfigurationChange`; SCK stop via `SCStreamDelegate`) both forward to `onInterruption` → `failSession`.

## Trade-offs & risks

- **Residual echo** is possible on loud external speakers (VPIO can't cancel everything); acceptable for STT, and headphones eliminate the bleed entirely. A future "headphones give best results" hint could help.
- **VPIO's macOS AEC-reference-is-system-output** behavior is the load-bearing assumption. Like Phase 1, this needs **on-device verification on a stably-signed build inside the App Sandbox** (dev/ad-hoc signing forgets TCC grants each launch and looks like a bug). Existing entitlements suffice — no new entitlement is needed for VPIO or SCK.
- Hard-clip on summation (vs. attenuating each source) can distort when voice and system are simultaneously full-scale; rare in practice and fine for STT.

## Files

New: `MixedAudioCaptureService.swift` (+`+Mic`), `AudioRingBuffer.swift`.
Edited: `AudioCaptureSource.swift` (enum case + factory + `requiresMicrophone`), `MacLiveTranscriptionView+AudioSource.swift` (dual-grant gating), `MacTranscriptionViewModel+AudioSource.swift` (interruption copy).

## Verification

Build the **OpenCaptions** scheme in Xcode. Pick "Microphone + System Audio" → grant Microphone + Screen Recording (relaunch on first screen grant) → play another app's audio while speaking → confirm one transcript with **both** the system audio and your voice, and that the system audio is **not** transcribed twice on built-in speakers. Test denied states for each grant; test live switching among all three sources (socket + transcript preserved). Validate on a **stably-signed** build inside the sandbox. CI: `scripts/check-file-length.sh OpenCaptions`.
