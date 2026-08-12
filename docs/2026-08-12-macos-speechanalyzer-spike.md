# Spike: gating Apple's `Speech`/`SpeechAnalyzer` behind `if #available(macOS 26.0, *)`

**Date:** 2026-08-12 · **Scope:** Research spike, no app code changed at time of writing this
doc · **Part of:** #53 (adds `SpeechAnalyzer` as a 4th on-device engine)
**Related:** `docs/2026-08-12-coreai-parakeet-spike.md` (#44 — the comparison-methodology
reference #53 names; that spike concluded a **hard** `.macOS("27.0")` SPM platform pin forces a
separate plugin/dlopen target), `docs/2026-08-12-macos-transcription-engine-selector.md` (#35 —
the three-way selector this issue extends to four)

## Context

WWDC25 introduced an overhauled `Speech` framework — `SpeechAnalyzer` + `SpeechTranscriber` — for
on-device transcription, macOS 26+. Unlike #44's `apple/coreai-models` (a third-party SPM package
that hard-pins `platforms: [.macOS("27.0")]`, forcing a plugin/dlopen-isolated target since a
14.4+-floor target can't link it at all), `Speech` is a **first-party system framework** available
in the SDK unconditionally — the question is only whether Apple's normal per-symbol `@available`
annotations let a 14.4+-floor target call into it directly, the same way the codebase already
gates the Liquid Glass visual style (`Views/Common/View+LiquidGlass.swift:19`,
`Views/LiveTranscription/CaptionsOverlayView.swift:207`). #53's acceptance criteria required
confirming this **before** the rest of the issue proceeds.

Environment: Xcode 27.0 beta / macOS 27.0 SDK on this dev machine (`xcrun --sdk macosx
--show-sdk-path` → `.../MacOSX27.0.sdk`). Verified hands-on via `swiftc -typecheck`, not desk
review — both at initial research time and re-confirmed at implementation time in this same
session (the two runs agreed).

## Findings

1. **The core assumption is correct — no deployment-target bump, no plugin isolation needed.**
   A file using `SpeechTranscriber`/`SpeechAnalyzer`/`AssetInventory` only inside
   `if #available(macOS 26.0, *)` blocks type-checks with **zero** errors or warnings under
   `swiftc -target arm64-apple-macos14.4 -sdk <SDK>`. The same symbols referenced **unguarded**
   correctly **fail**:
   ```
   error: 'SpeechTranscriber' is only available in macOS 26 or newer
   note: add 'if #available' version check
   ```
   This is materially simpler than #44's finding: there is no whole-package-graph platform floor
   to fight, because `Speech` ships in the SDK itself rather than as an SPM dependency with its
   own `Package.swift`.

2. **Gotcha: `AnalyzerInputConverter` is macOS 27+, not 26+.** Its whole point is
   auto-converting an arbitrary `AVAudioPCMBuffer` into `[AnalyzerInput]` for the analyzer's
   preferred format — the obvious tool to reach for — but it fails to compile under a
   `macOS 26.0` gate:
   ```
   error: 'AnalyzerInputConverter' is only available in macOS 27 or newer
   ```
   confirmed via the same typecheck technique, gated at `if #available(macOS 26.0, *)`.
   **Workaround** (also spike-verified, compiles clean at macOS 26+): get the analyzer's
   preferred format via `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, hand-roll the
   conversion with a plain `AVAudioConverter` — the same idiom `NemotronPostSessionEngine.swift`
   already uses for its own file-decode loop — then wrap the converted buffer with
   `AnalyzerInput(buffer:)`, which *is* available at macOS 26 per the swiftinterface.

3. **`AttributedString` run attribute access (`.audioTimeRange`) also type-checks clean under
   the macOS 26 gate.** Needed for real per-word timestamps in the post-session engine
   (`attributeOptions: [.audioTimeRange]` on `SpeechTranscriber`, then each run's
   `.audioTimeRange` dynamic member via `AttributeDynamicLookup`) — verified as returning
   `CMTimeRange?` per run, matching the pattern of reading an optional per-run attribute.

4. **API surface reference** (742 lines, fast full read — don't reverse-engineer from memory or
   web search): `<SDK>/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
   where `<SDK>` = `xcrun --sdk macosx --show-sdk-path`. Has the exact `@available` annotation for
   every symbol — `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`, `AnalyzerInput`,
   `AnalyzerInputConverter` (27+, see finding 2), `AssetInstallationRequest`, etc.

## Key API behaviors that shaped the implementation

- **`AssetInventory.Status`**: `.unsupported / .downloading / .supported / .installed`. Maps onto
  the existing `FluidAudioModelManager`-style `notDownloaded/downloading/ready/failed` shape as:
  `installed` → ready, `supported` → notDownloaded, `downloading` → downloading (no fraction from
  this API — only from a triggered `AssetInstallationRequest`), `unsupported` → failed.
  `AssetInventory.assetInstallationRequest(supporting:)` returns `nil` when there's nothing to
  install (already installed, or unsupported) — `status(forModules:)` disambiguates which.
- **`AssetInstallationRequest.progress`** is a plain `Foundation.Progress` (KVO, not async) —
  observed with `.observe(\.fractionCompleted, options: [.new])`, invalidated when done.
- **`SpeechTranscriber.Result.text` is incremental per-result**, not the full-accumulated-
  transcript-each-time shape Nemotron's FluidAudio manager reports. Each **final** result is its
  own new segment to append; each **non-final** (volatile) result *replaces* the currently-
  displayed partial — matching Parakeet's confirmed/volatile handling
  (`ParakeetTranscriberService.handle(_:)`), not Nemotron's full-transcript diffing.
- **Post-session/batch has a purpose-built path**: `SpeechAnalyzer.start(inputAudioFile:finishAfterFile:)`
  reads a whole file end-to-end with no manual `AVAudioFile`/`AVAudioConverter` decode loop —
  unlike `NemotronPostSessionEngine`, which needs one because FluidAudio exposes no URL-based
  batch call for Nemotron. Pattern: `async let startResult: Void = analyzer.start(inputAudioFile:finishAfterFile:)`
  run concurrently with `for try await result in transcriber.results { ... }`, then
  `try await startResult` afterward to propagate any error.

## Recommendation: **proceed**

Unlike #44's Core AI Parakeet spike (deferred — hard macOS 27+ SPM platform pin), `Speech`/
`SpeechAnalyzer` needs no deployment-target bump and no plugin/dlopen isolation to reach a
14.4+-floor target: a plain `if #available(macOS 26.0, *)` gate is sufficient, confirmed by
direct compilation rather than documentation reading. The rest of #53 (the engine case, live and
post-session services, model-readiness manager, factory wiring) proceeds on this basis.

## Verification

Hands-on, on this dev machine (macOS 27.0 / Xcode 27.0 beta), both at initial spike time and
re-confirmed at implementation time in the same session (identical results):

1. `swiftc -target arm64-apple-macos14.4 -sdk <SDK> -typecheck` on a file using
   `SpeechTranscriber`/`SpeechAnalyzer`/`AssetInventory` only inside `if #available(macOS 26.0, *)`
   — zero errors.
2. The same symbols referenced unguarded in a separate file — confirmed the expected
   `'SpeechTranscriber' is only available in macOS 26 or newer` compile error.
3. `AnalyzerInputConverter` referenced inside a `macOS 26.0` gate — confirmed the expected
   `'AnalyzerInputConverter' is only available in macOS 27 or newer` compile error (finding 2).
4. A combined typecheck of the planned live-capture shape (custom `SpeechTranscriber` init,
   `SpeechAnalyzer(modules:)`, `bestAvailableAudioFormat`, `prepareToAnalyze`, `AnalyzerInput(buffer:)`,
   `AsyncStream<AnalyzerInput>` feeding `start(inputSequence:)`, consuming `transcriber.results`)
   and the planned post-session shape (`start(inputAudioFile:finishAfterFile:)` run concurrently
   with the results loop, reading `run.audioTimeRange`) — zero errors, both gated at macOS 26.0.
5. Read the full `Speech.swiftmodule` `.swiftinterface` (742 lines) rather than guessing method
   signatures from memory or web search.

No actual audio was transcribed in this spike — all verification is `-typecheck` (API shape and
availability-gating correctness), not a runtime smoke test. Runtime behavior is verified
separately once the concrete engines land (see `docs/2026-08-12-macos-speechanalyzer-engine.md`).

## Follow-ups not taken

- **No runtime smoke test in this spike** — confirming the gate compiles is a distinct question
  from confirming the analyzer actually transcribes correctly at runtime; the latter is covered by
  the feature doc's own verification section once the concrete engines exist.
- **No accuracy/latency comparison against Nemotron/Parakeet/Soniox** — out of scope for a spike
  answering "does the availability gate work," matching #44's own scoping precedent.
