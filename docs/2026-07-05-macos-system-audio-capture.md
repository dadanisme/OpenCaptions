# macOS System-Audio Capture (ScreenCaptureKit) — #176

**Date:** 2026-07-05 · **Target:** OpenCaptions · **Epic:** #103 · **Depends on:** #171 (MVP)

## Problem

On the desktop the highest-value transcription source is often *other apps'* audio (video calls, meetings, media) — which iOS can't capture but macOS can. #176 adds selectable system-audio capture to Open Captions, feeding the existing Soniox pipeline.

## Delivery (phased)

- **Phase 1 (this work):** Microphone **or** whole-system audio as a selectable, live-switchable source. Satisfies the issue's core acceptance criteria at low risk.
- **Phase 2 (#189):** Microphone **+** system audio *mixed*, with acoustic echo cancellation so the mic's speaker-bleed doesn't double the system audio. Higher risk (needs on-device verification), split out.

## Architecture

Provider-agnostic capture behind `AudioCaptureSource` (`OpenCaptions/Services/Audio/AudioCaptureSource.swift`):
`onInterruption`, `start() async throws -> AsyncStream<AudioFrame>`, `stop()`, `pause()`, `resume() throws`. Both `MacAudioService` (mic) and `SystemAudioCaptureService` (SCK) conform and emit the identical 16 kHz / mono / Float32 `AudioFrame`, so `MacTranscriptionViewModel`'s chunking / Soniox-send / pause-resume machinery is source-agnostic. Source kinds map to services via `AudioSource` (enum, persisted rawValue) + `AudioCaptureSourceFactory`. `MacTranscriptionViewModel.audio` is typed `any AudioCaptureSource`; `start(...)` takes a `source:`; live switching is `MacTranscriptionViewModel+AudioSource.switchAudioSource(to:)` (reuses the `pushGeneration` teardown to keep the Soniox socket + transcript). UI: transport-pill `Menu` over `AudioSource.allCases` (Phase 2's third case appears automatically).

## Key decisions & findings

- **ScreenCaptureKit, not CoreAudio process taps.** `AudioHardwareCreateProcessTap` requires macOS **14.2+**; the deployment target is **14.0**, so SCK is the only option. SCK audio APIs used are all 13.0+.
- **Audio-only `SCStream` on 14.0.** Add only the `.audio` output (no `.screen`, no `AVAssetWriter`), but a tiny video config is still required: `width/height = 2`, `minimumFrameInterval = 1 fps`. Config: `capturesAudio = true`, `excludesCurrentProcessAudio = true` (avoids capturing our own TTS/output), `sampleRate = 16000`, `channelCount = 1`. Whole-system filter: `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` → `displays.first` → `SCContentFilter(display:excludingWindows: [])`. SCK honors 16 k/mono but the code reads the real ASBD and converts defensively (one reused `AVAudioConverter`, `downmix = true`, one-shot input block, `autoreleasepool`; convert inside `withAudioBufferList` and yield only the owned buffer — the no-copy buffer is a borrowed view). Per-app / `SCContentSharingPicker` selection deferred.
- **Permission is pure runtime TCC — no entitlement, no Info.plist key.** `CGPreflightScreenCaptureAccess()` to check, `CGRequestScreenCaptureAccess()` to prompt. **On macOS 14 the first grant requires an app relaunch** before an `SCStream` will start → a dedicated "needs relaunch" state. Denied/relaunch UI mirrors the mic-denied `ContentUnavailableView` (`MacAudioPermissionView`); deep-link `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. Mid-session revocation surfaces via `SCStreamDelegate.stream(_:didStopWithError:)` → `onInterruption` → `failSession` (keeps the transcript).
- **No SCStream pause.** Soft-pause gates frame delivery with an `isPaused` flag (early-return before conversion), composing with the existing keepalive-during-pause design.
- **Sandbox / App Store.** SCK ships in sandboxed MAS apps using only public API; the existing entitlements suffice (no `com.apple.security.screen-capture` — it doesn't exist). The orange recording indicator is always shown. **Highest risk: verify capture actually flows inside the App Sandbox on a stably-signed build** — dev/ad-hoc signing "forgets" the TCC grant each launch and looks like a bug.
- **New files auto-compile.** `OpenCaptions` is a `PBXFileSystemSynchronizedRootGroup`, so new `.swift` files under `OpenCaptions/` need no pbxproj Sources edits.

## Echo cancellation for Phase 2 (VPIO) — researched, recorded in #189

macOS `AVAudioInputNode.setVoiceProcessingEnabled(true)` runs AEC against the **hardware output mix, including other apps' audio** (verified against a shipping mic+SCK transcription app), so it cancels the mic's speaker-bleed with no custom reference and no third-party library. Gotchas: **disable advanced ducking** (`voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`) or the SCK system audio gets attenuated; **handle the multi-channel VP input format** (read live format / extract channel 0); optionally disable AGC. Mix in **software** (bounded ring buffers) — do NOT route SCK audio through the engine output (replays to speakers + doubles). Residual echo is possible on loud external speakers (acceptable for STT; headphones = no bleed).

## Concurrency notes

- `switchAudioSource` is synchronous and returns whether it applied; the picker persists the choice only on success (avoids picker/capture divergence + mis-persisting during the connect window when no pump is live yet).
- `SystemAudioCaptureService.stop()` records a `stopRequested` flag before `isRunning` flips, and `start()` re-checks it after the async `startCapture()` — so a stop that races the async startup still tears the stream down (no orphaned system-audio capture after "stop").
- The background sample-handler queue reads shared `continuation`/`converter` while MainActor mutates them — the same latent pattern already present in `MacAudioService`'s tap; not hardened here (would need locks on both paths — a separate pass).

## Files

New: `AudioCaptureSource.swift`, `SystemAudioCaptureService.swift` (+`+Output`), `MacTranscriptionViewModel+AudioSource.swift`, `MacAudioPermissionView.swift`, `MacLiveTranscriptionView+AudioSource.swift`.
Edited: `MacAudioService.swift`, `MacTranscriptionViewModel.swift`, `MacLiveTranscriptionView.swift`, `MacTranscriptionControls.swift`.

## Verification

Build the **OpenCaptions** scheme in Xcode. Pick System Audio → grant Screen Recording → relaunch → play another app's audio → confirm a live transcript; test denied state + deep-link; test live mic↔system switching (socket + transcript preserved); confirm the mic-only path is unchanged; **validate on a stably-signed build inside the sandbox**. CI: `scripts/check-file-length.sh OpenCaptions`.
