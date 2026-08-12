# macOS: streaming Nemotron ASR via Apple Core AI, live + batch (#55)

**Date:** 2026-08-12 · **Scope:** `CoreAIPlugin` sibling package + `OpenCaptions`
**Related:** `docs/2026-08-12-macos-coreai-plugin-skeleton.md` (#47 — the dlopen'd-sibling-package
architecture this reuses unchanged), `docs/2026-08-12-macos-transcription-engine-selector.md`
(#35 — the live picker this extends with a 5th, conditionally-shown case), and
`docs/2026-08-12-macos-speechanalyzer-engine.md` (#53 — merged into `main` while this issue was
in progress; rebasing onto it surfaced that both independently built the same
`OnDeviceEngineModelManaging` abstraction for the identical reason — see below)

## Context

[coreai-community/Nemotron-3.5-ASR-Streaming-CoreAI](https://huggingface.co/coreai-community/Nemotron-3.5-ASR-Streaming-CoreAI)
(a third-party conversion of NVIDIA's `nemotron-3.5-asr-streaming-0.6b`, OpenMDW-1.1) claimed a
**cache-aware streaming architecture** — 320ms chunks, explicit KV-sliding-window/causal-conv
graph I/O, no 30s cap — unlike the existing Core AI Parakeet integration (#47), whose
`coreai-kit` bundle is fixed-bucket (~28.84s) and batch-only. Worth checking whether that claim
holds, since a genuinely streaming Core AI model would be the first one reachable from **live**
capture rather than only batch re-transcription.

It holds. `john-rocky/coreai-kit` 0.3.0 — already the exact version this repo's `CoreAIPlugin/
Package.swift` pins for Parakeet — ships `KitNemotronModel`/`NemotronStreamSession`
(`Sources/CoreAIKit/Nemotron/`), added upstream 2026-07-05. Read directly (not just the model
card): `NemotronStreamSession.feed(samples:)` carries real state between calls — KV/conv caches
and RNN-T decoder state round-tripped as the graphs' own tensors — and returns the transcript
decoded from however many complete 320ms chunks have accumulated so far. There is no fixed
encoder bucket to chunk around, unlike Parakeet. No `Package.swift` change was needed at all —
the dependency was already there.

## Decision: reuse the #47 dlopen boundary; a session crosses it as its own object

Same architecture as #47 end to end — sibling SPM package pinned to `.macOS("27.0")`, built as a
`.dylib` by the existing Run Script phase, loaded via `dlopen`/`dlsym`, gated behind
`#available(macOS 27.0, *)`. What's new is **two** duplicated `@objc` protocols instead of one
(`CoreAIPluginProtocol+Nemotron.swift`, byte-for-byte identical on both sides of the boundary,
same convention as `CoreAIPluginProtocol.swift`):

- `CoreAINemotronTranscriptionPlugin` — `isModelDownloaded()`, `downloadModel(progress:completion:)`,
  `makeSession(language:completion:)`.
- `CoreAINemotronSession` — `feed(samples:completion:)`, `finish(completion:)`.

Parakeet's protocol is one call: hand over a file URL, get a transcript back. Nemotron's
streaming architecture doesn't fit that shape — a caller needs to feed chunks as they arrive and
read back a growing transcript — so the session itself crosses the dlopen boundary as an
`@objc`-protocol-typed object, returned through a completion closure exactly like the existing
`(String?, Error?)` closures already do. Audio crosses as raw `Data` (16 kHz mono Float32 LE
bytes, the same convention `RealtimeTranscriptionEngine.sendAudioChunk(_ data: Data)` already
uses) rather than `[Float]`, which isn't `@objc`-representable; the plugin side reinterprets the
bytes back with `withUnsafeBytes`/`bindMemory`.

**The compiled model is cached inside the plugin** (`CoreAINemotronPlugin.ModelCache`, an actor)
for the dylib's lifetime, unlike `CoreAIParakeetPlugin`, which reconstructs `KitParakeetModel`
fresh on every `transcribe()` call. This matters far more here: the model card states a ~50s
first-load cost (GPU specialization compiling six on-device graphs) vs. ~4s once cached, and
Nemotron backs a live engine where that cost would otherwise land inside `connectAndStart()` on
every single session. Paying it once, from an explicit Settings **Download** tap
(`downloadModel(progress:completion:)` calls through to the same cached load), means a live
session only ever hits the cheap cached path.

## Decision: reachable from BOTH pickers, unlike Parakeet

Because Nemotron is real streaming, it needed a live case too —
`MacTranscriptionEngineKind.coreAINemotron` — not just the batch
`RetranscriptionEngineKind.coreAINemotron` #47's Parakeet case is confined to. Both are gated
behind `CoreAIPluginLoader.isAvailable` via each enum's own `availableCases` (a new one added to
`MacTranscriptionEngineKind`, which had no gating mechanism before this — `allCases` was used
directly everywhere). `LiveSessionStore.retranscriptionEngineKind`'s live→batch mapping switch
gained a `.coreAINemotron: .coreAINemotron` branch alongside the pre-existing three.

The batch (`CoreAINemotronPostSessionEngine`) and live (`CoreAINemotronTranscriberService`)
engines share the SAME session-based plugin protocol — batch decodes a file a few seconds at a
time (`AVAudioFile`/`AVAudioConverter`, mirroring `NemotronPostSessionEngine`) purely to report
progress fractionally, then calls `session.finish()` once at the end; live feeds the session
straight from `sendAudioChunk`. Both diff the running transcript with the existing
**`FluidAudioStreamBridge.tokens(forFull:confirmedPrefix:)`** — that diffing/segmentation logic
turned out to be entirely engine-agnostic (it only needs "the growing full transcript string"),
so the live engine reuses it exactly like `NemotronTranscriberService` does, with no changes to
that shared file.

## `OnDeviceEngineModelManaging` — a third conformer, not a new abstraction

Issue #55 asked to mirror `FluidAudioModelLoader`'s per-model Download control. #53 (Apple
Speech/`SpeechAnalyzer`, merged into `main` first) had already hit the identical need — a
second, non-FluidAudio download mechanism (`AssetInventory`) needing the same
download/progress/ready UI — and extracted `OnDeviceEngineModelManaging` +
`OnDeviceModelStatus` (`Utility/OnDeviceModels/OnDeviceModelManaging.swift`) for exactly that
reason. `CoreAINemotronModelManager` here is simply the third conformer, delegating to
`CoreAIPluginLoader.makeNemotronPlugin()`; no new protocol was needed by the time this landed.

## Decision: no diarization, no term biasing, no multilingual for v1

All three answer explicit open questions in the issue:

- **Diarization stays unsupported** — `supportsDiarization: false` on both engines, consistent
  with every other on-device engine. Worth a flag for later: `coreai-kit` already ships a
  Sortformer diarizer (`KitDiarizer`), unused here — enabling it is a real option for a future
  issue, just out of scope for this one.
- **No term biasing** — neither `KitNemotronModel` nor `NemotronStreamSession` takes any
  vocabulary/context argument; only `language`. Matches the FluidAudio on-device engines, which
  also take no biasing hook.
- **English-only** — the model supports 40 locales (`KitNemotronModel.languages`), but the rest
  of the app hardcodes English throughout (summary prompt language, no localization). Both new
  engines hardcode `language: "en-US"`. Surfacing a locale picker is a separate, larger issue.

## What's new

- **`CoreAIPlugin/Sources/CoreAIPlugin/`** — `CoreAIPluginProtocol+Nemotron.swift` (protocols),
  `CoreAINemotronPlugin.swift` (`CoreAINemotronPlugin` + `CoreAINemotronSessionImpl`,
  `NSObject` conformers backed by real `KitNemotronModel`/`NemotronStreamSession`). Second
  `@_cdecl` factory in `CoreAIPluginEntry.swift`.
- **`OpenCaptions/Services/Retranscription/CoreAI/`** — `CoreAIPluginProtocol+Nemotron.swift`
  (duplicate), `CoreAIPluginLoader.swift` extended with `makeNemotronPlugin()` +
  `isNemotronModelDownloaded()` (shared `loadHandle()` cache with the existing `makePlugin()`),
  `CoreAINemotronPostSessionEngine.swift` (conforms to `PostSessionTranscriptionEngine`).
- **`OpenCaptions/Services/Transcription/CoreAI/`** (new directory) —
  `CoreAINemotronTranscriberService.swift` (conforms to `RealtimeTranscriptionEngine`).
- **`OpenCaptions/Utility/OnDeviceModels/CoreAINemotronModelManager.swift`** (new) — the third
  conformer to `OnDeviceEngineModelManaging` (see above), alongside `FluidAudioModelManager` and
  #53's `AppleSpeechModelManager`.
- **`RetranscriptionEngineKind.coreAINemotron`** — new case, gated into `availableCases` on
  `CoreAIPluginLoader.isAvailable` alongside `.coreAIParakeet` and #53's `.appleSpeech`.
- **`MacTranscriptionEngineKind.coreAINemotron`** — new case, gated into the manual `allCases`
  (the live enum dropped `CaseIterable` in #53 in favor of a hand-written, already-filtered
  `allCases`) alongside `.appleSpeech`'s macOS-26 gate.
- **Doc-comment fixes in passing**: `CoreAIParakeetPostSessionEngine.swift` and
  `PostSessionRetranscriptionFactory.swift` still called the Parakeet-via-Core-AI path a "stub"
  — stale since #47's own follow-up already wired real `KitParakeetModel` transcription; updated
  to match what the code (and `docs/README.md`'s own row) already says.

## Follow-ups not taken

- **Diarization via `KitDiarizer`** — see "Decision" above. A real option, deliberately out of
  scope here.
- **Multilingual UI** — locale picker, `"auto"` language ID. Out of scope while the app is
  English-only everywhere else.
- **No automated runtime verification** — same constraint as #47: no UI-automation tool for a
  native macOS window in this environment. Verified: clean `BuildProject`. Still owed manually:
  downloading the model from Settings → General, confirming a live session actually transcribes
  with the Core AI Nemotron engine selected, and that batch re-transcription (via the
  Re-transcription Engine override) produces a real transcript rather than an empty result.
- **No pre-warm at app launch** — the Settings Download control is the only way to pay the ~50s
  first-compile ahead of a session; there's no background pre-warm on first launch after
  download completes. Not addressed here since it would need its own lifecycle hook and isn't
  what the issue asked for.

## Verification

Build the **OpenCaptions** scheme via the Xcode MCP (`BuildProject`). See "Follow-ups" above for
what's still owed as manual, in-app verification.
