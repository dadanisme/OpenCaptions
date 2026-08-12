# Spike: Apple Core AI's Parakeet export vs. FluidAudio

**Date:** 2026-08-12 · **Scope:** Research spike, no app code changed · **Closes:** #44
**Related:** #35 (Offline Mode → per-model selector — this spike's recommendation feeds
directly into it), `docs/2026-07-10-macos-on-device-engines.md` (the current FluidAudio
Parakeet/Nemotron integration this was compared against)

## Context

Apple's [`apple/coreai-models`](https://github.com/apple/coreai-models) (BSD-3-Clause)
ships export recipes + a Swift runtime for **Core AI**, the macOS/iOS 27.0+ successor to
Core ML for on-device generative/speech AI. Its catalog includes a Parakeet TDT export —
the same NVIDIA architecture family Open Captions already runs on-device via FluidAudio
(`ParakeetTranscriberService` live, `ParakeetPostSessionEngine` post-session/import). #44
asked whether Core AI's own Parakeet is a viable replacement, starting Parakeet-only.

This dev machine happens to already run macOS 27.0 / Xcode 27.0 (build `26A5388g` /
`27A5228h`), so the spike was done **hands-on** rather than as a desk review: the repo was
cloned, the export pipeline actually run, a real `.aimodel` bundle produced, and the
resulting Swift CLI tool built and run against a synthetic test clip.

## Findings

1. **Hard platform floor: `.macOS("27.0")`.** `coreai-models`'s `Package.swift` pins
   `platforms: [.macOS("27.0"), .iOS("27.0")]`. Open Captions targets macOS 14.4+; adopting
   the Swift runtime package at all — independent of any accuracy/latency finding below —
   means bumping the deployment target 13 major versions. Disqualifying on its own today.

2. **No streaming path.** The exported bundle's Swift API
   (`swift/Sources/CoreAISpeech/SpeechRecognitionModel.swift`) exposes only
   `transcribe(audioURL:)` / `transcribe(pcm:)` — full-utterance batch calls, no
   incremental decode method and no partial-result callback. The model README says why:
   *"cache-aware / chunked-attention streaming is not yet implemented in `transformers` for
   Parakeet"* — the recipe can only export a full-utterance encoder until that lands
   upstream. This is strictly **weaker** than what Open Captions already has: FluidAudio's
   `SlidingWindowAsrManager` at least fakes live Parakeet captions via a tuned overlapping
   re-encode window (`ParakeetEngineConfig.responsiveStreaming`); Core AI's export can't do
   that at all yet. Live capture would still need Nemotron (or FluidAudio's Parakeet) —
   Core AI's Parakeet could only ever target the post-session/import path.

3. **The static export silently truncates long audio (found empirically).** `export.py`
   defaults to a static 5-second-window trace (`--audio-seconds 5.0`). Feeding a 13-second
   synthetic test clip (generated locally via `say`) through that default export cut the
   transcript off mid-sentence at the window boundary — no error, just missing audio.
   `--dynamic` fixes this (variable-length encoder), but it's still one full-utterance
   batch call, not streaming; anyone using the documented default flags for anything longer
   than ~5s would silently lose audio, which is worth flagging upstream regardless of the
   adopt/defer outcome here.

4. **Accuracy and latency (dynamic export, single clean clip).** Built
   `swift run -c release speech-recognizer` and ran it against the 13s synthetic clip
   above. Transcription was verbatim-correct, including punctuation and casing
   ("...speech-to-text transcription with speaker diarization, live captions, and AI
   summaries..."). Timing: ~2.8 ms mel preprocessing + ~68.7 ms encoding + 132 ms decode
   (83 steps, 0.7 ms/step) ≈ **203 ms to transcribe 13 s of audio** (~64x real-time), after
   a one-time ~2.6 s graph-specialization warmup. This is one clean single-speaker clip, not
   a WER benchmark, and no equivalent FluidAudio number was gathered in this spike (that
   would need instrumenting the shipped app, not just the CLI) — treat as a sanity check
   that the export produces a working, fast model, not as a head-to-head number.

5. **Bundle size: ~1.2 GB (float16), no quantized export option.** The exported bundle
   (encoder + decoder_step + joint `.aimodel` assets, `nvidia/parakeet-tdt-0.6b-v3`,
   float16) totals 1.2 GB, almost entirely the encoder (1.1 GB). `export.py --dtype` only
   offers `float16`/`float32` — no int8/int4 quantized path. FluidAudio's existing Parakeet
   download is described in-repo only qualitatively ("multi-hundred-MB network fetch" —
   `ParakeetTranscriberService.swift:79`), but is clearly lighter; CoreML's own conversion
   evidently applies more aggressive compression than Core AI's export does today.

6. **No distribution story of its own.** There is no hosted registry of pre-converted
   `.aimodel` bundles to download at runtime — a shipping app has to either bundle the
   ~1.2 GB asset itself or run the Python export pipeline once and host/distribute the
   result on its own infrastructure. FluidAudio's `ModelHub`/`AsrModels` (what
   `FluidAudioModelLoader` already wraps) is a materially more turnkey "download by repo
   id" flow.

7. **No vocabulary/term-biasing hook.** `SpeechRecognitionModel.transcribe` takes no
   context/biasing parameter of any kind. Not a regression *today* (on-device paths in
   Open Captions don't do term-biasing regardless — cloud-only, per CLAUDE.md), but it
   forecloses closing that gap later the way FluidAudio's
   `SlidingWindowAsrManager.configureVocabularyBoosting` at least leaves open for Parakeet.

8. **Licensing: compatible.** `LICENSE` is a plain 3-clause BSD, same shape as the
   project's existing vendored SpeexDSP / FluidAudio dependencies. No concerns.

9. **Model variant differs.** The recipe exports `nvidia/parakeet-tdt-0.6b-v3`; FluidAudio's
   current integration runs `parakeet-tdt-0.6b-v2`. Same architecture family, newer
   upstream checkpoint — not evaluated for an accuracy delta here, and orthogonal to the
   Core-AI-vs-FluidAudio question since FluidAudio could in principle pick up v3 too.

## Recommendation: **defer**

The macOS 27+ floor alone is disqualifying while this app targets 14.4+ — nothing below
changes that. Independent of the platform question, Core AI's Parakeet export is
batch-only with no streaming path (weaker than FluidAudio's existing live workaround),
ships a heavier default bundle with no quantization option, and has no runtime
distribution mechanism of its own. Revisit once **both** (a) Core AI targets a deployment
floor this app could plausibly adopt, and (b) a streaming-capable Parakeet export lands
upstream in `transformers` — until then it can't even reach parity with what FluidAudio
already does. **#35 should proceed entirely on the existing FluidAudio engines** (Nemotron
+ Parakeet); this spike changes nothing about that plan.

## Verification

Hands-on, on this dev machine (macOS 27.0 / Xcode 27.0 beta):

1. `git clone` of `apple/coreai-models`; `LICENSE` and `Package.swift` read directly.
2. `uv run models/parakeet/export.py --dtype float16 --overwrite` — resolved dependencies
   (including Apple's prerelease `coreai-core`/`coreai-torch` packages) and produced a
   working static-window bundle.
3. `uv run models/parakeet/export.py --dtype float16 --dynamic --overwrite` — produced a
   dynamic-length bundle.
4. `swift build -c release --product speech-recognizer` against the repo's own
   `Package.swift`.
5. Generated a 13 s synthetic 16 kHz mono test clip locally (`say` → `afconvert`) and ran
   the built CLI against both bundles — reproduced the static-window truncation (finding
   #3) and confirmed correct, fast transcription on the dynamic bundle (finding #4).

No FluidAudio-side re-benchmarking was done as part of this spike — its numbers cited above
are from existing code comments/docs, not fresh measurement.

## Follow-ups not taken

- **No formal WER/accuracy benchmark** against a real (non-synthetic, accented/noisy)
  corpus for either engine — out of scope for a spike answering "is this even viable."
- **No upstream issue filed** against `apple/coreai-models` about the silent 5s truncation
  default (finding #3) — worth doing separately if this project keeps tracking the repo,
  but not required to close #44.
- **No attempt to run Core AI's Parakeet live** (chunked/streaming) — the README already
  rules this out; no runtime experiment could change that until upstream `transformers`
  gains a chunked-attention Parakeet encoder.
