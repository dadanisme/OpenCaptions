# macOS on-device transcription engines: Parakeet TDT v2 + Nemotron 560ms

**Date:** 2026-07-10

## Context

Open Captions shipped its MVP with **cloud Soniox only**. The goal here is to evaluate whether
on-device transcription is viable on macOS and, if so, to expose it. The `FluidAudio` SPM package
provides production-ready Parakeet and Nemotron engines, but that package was **not linked to the
OpenCaptions target** and none of the engine code existed here yet.

Product ask (user): add **NVIDIA Parakeet TDT v2** (English-only, highest accuracy) and **Nemotron
560ms** (native low-latency streaming) as selectable engines, with a **Soniox / Parakeet / Nemotron
toggle in Settings** and a **model-download UI** (the models are large and fetched on demand).

## Decisions

1. **Parakeet = TDT v2 (`parakeet-tdt-0.6b-v2`) via FluidAudio's built-in `SlidingWindowAsrManager`.**
   TDT v2 is an offline batch transducer; FluidAudio now ships the sliding-window streaming
   "workaround" natively (an actor: `start(models:)` / `streamAudio(_:)` / `transcriptionUpdates` /
   `finish()`), so we did **not** hand-port VoiceInk's LocalAgreement engine. This is dramatically
   less code (the built-in replaces ~700 lines of stateful LocalAgreement/sliding-window logic with
   one actor). We chose TDT v2 over FluidAudio's separate `parakeetEou` streaming model because the
   user explicitly wanted the higher-accuracy 0.6B TDT v2.

2. **No FluidAudio pin bump.** The repo already resolves FluidAudio at `f3dba78` (branch `main`),
   which contains `SlidingWindowAsrManager`, `NemotronStreamingAsrManager`, **and**
   `StreamingEouAsrManager`. Linking the package to the OpenCaptions target reuses the existing
   project-level package reference, so no dependency-resolution change is needed.

3. **Nemotron fixed at 560ms** (native streaming; punctuation-driven finalization via the
   `FluidAudioStreamBridge`). No chunk-size variant picker.

4. **Engine toggle + model-download cards live in Settings → Recording** (a "Transcription Engine"
   section), always visible (Open Captions has no `engineSelector`-style flag; the user wanted it shown).

## Latency finding (important — evaluate before shipping Parakeet)

`SlidingWindowAsrManager` produces one update **per `chunkSeconds`** — its `.streaming`/`.default`
presets use an 11–15 s main chunk, and the advertised `hypothesisChunkSeconds` fast-track is **unused
in this FluidAudio build**. At the preset, live text would only refresh every ~11 s — too coarse for
live captions. We therefore ship a **responsiveness-tuned config**
(`ParakeetEngineConfig.responsiveStreaming`: 5 s main chunk, 10 s left context, 2 s right context,
5 s min-confirmation context, 0.85 threshold) so confirmed text advances roughly every ~5 s (first at
~7 s), trading extra CoreML compute for a more live feel.

**Critical coupling — `chunkSeconds + rightContext >= minContextForConfirmation`.** The manager only
promotes volatile→confirmed text once `minContextForConfirmation` seconds of audio have arrived; any
window processed before that stays volatile and is *discarded* when the next window replaces it. So a
small `chunkSeconds` paired with a large `minContext` (e.g. the presets' 10 s) silently **drops the
first several seconds of speech**. We keep `minContext == chunkSeconds` (5 s) so the first window is
immediately confirmable and nothing is dropped. Preserve this relationship when tuning. Nemotron
560ms is genuinely low-latency (true streaming) and needs no such workaround.

## Escape hatch: VoiceInk engine

If the built-in sliding-window quality/latency proves inadequate in testing, swap
`ParakeetTranscriberService`'s **internals** for a VoiceInk-style LocalAgreement engine
(1 s transcribe loop over `AsrManager.transcribe(_:decoderState:)` + a `WordAgreementEngine`
LocalAgreement-3 with punctuation confirmation), behind the **same** `RealtimeTranscriptionEngine`
protocol. Nothing else changes — the view model, factory, settings, model download (same TDT v2
`AsrModels` files), and diarization-off UI all stay put. Reference:
`~/Documents/Workspace/Portofolio/VoiceInk/VoiceInk/Transcription/Streaming/`.

## Implementation

**FluidAudio layer (new, `OpenCaptions/`):**
- `Utility/FluidAudioStreamBridge.swift` — `makeBuffer(from:)` (16 kHz Float32 `Data` →
  `AVAudioPCMBuffer`) + `tokens(forFull:confirmedPrefix:)` (Nemotron's full-transcript diff →
  finals/partials with the punctuation + word-count safety net).
- `Utility/FluidAudioModelLoader.swift` — the two download mechanisms: Parakeet TDT v2 via
  `AsrModels.download/load/modelsExist` rooted at `AsrModels.defaultCacheDirectory(for: .v2)`;
  Nemotron via `DownloadUtils.downloadRepo(.nemotronStreaming560, …)` rooted at
  `applicationSupport/FluidAudio/Models`.
- `Utility/FluidAudioModelManager.swift` — `@Observable @MainActor`, one per engine
  (`.parakeet`/`.nemotron`); `Status { notDownloaded, downloading(_), ready, failed(_) }`,
  `download()`, `delete()`, `refreshStatus()`.
- `Model/FluidAudioEngineConfig.swift` — `NemotronEngineConfig(chunkSize:)` + `ParakeetEngineConfig`
  (holds the `SlidingWindowAsrConfig`, defaulting to `responsiveStreaming`).

**Engines (new, conform to the existing `OpenCaptions/Services/Transcription/RealtimeTranscriptionEngine.swift`):**
- `Services/NemotronTranscriberService.swift` — feed loop → `NemotronStreamingAsrManager.process`,
  `setPartialCallback` → bridge.
- `Services/ParakeetTranscriberService.swift` — feed loop → `SlidingWindowAsrManager.streamAudio`;
  a separate loop consumes `transcriptionUpdates`, reconstructs the manager's confirmed/volatile
  two-tier state from `(update.text, update.isConfirmed)`, emits confirmed deltas as finals and the
  volatile as the partial.
- `Services/MacTranscriptionEngineKind.swift` — `enum {soniox, parakeet, nemotron}` + a factory.

**Wiring (modified):**
- `ViewModel/MacTranscriptionViewModel.swift` — `start()` resolves the engine from
  `LiveSessionStore.transcriptionEngineKey`, pre-checks the model is downloaded (fails fast with a
  "download in Settings" hint), builds via the factory, and gates `connectAndStart()` with
  `isPreparingEngine` (`capabilities.requiresPreparation`).
- `ViewModel/MacTranscriptionViewModel+Accumulator.swift` — when
  `!capabilities.providesReliableTimestamps` (on-device), stamp bubble times from the session clock
  (`totalActiveTime`) instead of the token's `start_ms` (which is 0). The single-stream case already
  works: `speaker == -1` is both the accumulator's "unset" sentinel and the on-device value, so it
  never flushes on speaker change and merges into one stream.

  **Superseded 2026-07-29** (`2026-07-29-macos-live-line-building.md`): that file is deleted. The
  clock-vs-token stamping decision moved to `resolvedTimes(startMs:endMs:)` in
  `MacTranscriptionViewModel+Lines`, and the double meaning of `-1` is gone —
  `TranscriptionToken.unknownSpeaker` now means only "diarization unavailable", while "no bubble
  open yet" is `LiveLineCursor.speaker == nil`. On-device tokens all carry `unknownSpeaker`, so
  they still merge into one stream. `FluidAudioStreamBridge` also stopped waiting on punctuation:
  it finalizes everything but the last 8 words, so offline text lands in the transcript
  continuously.
- `Views/MacSettingsView.swift` — Recording tab "Transcription Engine" section (picker + conditional
  `MacFluidAudioModelCard`).
- `Views/MacPreparingModelOverlay.swift` (new) + `MacLiveTranscriptionView.swift` — "Preparing model…"
  overlay while the CoreML model loads; status subtitle mirrors it.
- Diarization-off display: hide the speaker label for `speaker <= 0` in
  `MacLiveTranscriptionView` and `MacSessionDetailView+Playback.swift` (captions overlay and the
  "Edit Speakers" affordance already gate on positive ids).
- The Xcode project's `project.pbxproj` — link the `FluidAudio` product to the OpenCaptions target (the only
  manual pbxproj edit; new source files auto-include via the filesystem-synchronized group).
- `LiveSessionStore.transcriptionEngineKey` (`opencaptions.transcription.engine`, default `soniox`),
  registered in `OpenCaptionsApp.init()`.

## Edge cases / caveats

- **Model not downloaded** → `connectAndStart()` throws; `start()` shows a "download it in Settings"
  hint rather than blocking on a fetch.
- **Apple Silicon only** — FluidAudio requires arm64; on Intel the model load throws and surfaces via
  the same failure path (no crash).
- **App Nap** — unchanged; `LiveSessionStore.updateBackgroundActivity()` already holds a
  `.userInitiated` assertion while running/paused (covers CoreML inference).
- **Pause/resume** — on-device `needsReconnect == false`; keepalive/zombie are no-ops. The
  `SlidingWindowAsrManager` / Nemotron state persists across a soft pause (no socket).

## Verification

Build the **OpenCaptions** scheme in Xcode (not xcodebuild). Settings → Recording → pick Parakeet TDT v2
→ Download → Ready; start a recording (Preparing overlay → single-stream transcript, timestamps from
0). Repeat for Nemotron 560ms. Switch back to Soniox and confirm diarization/speaker labels still
work.
