# macOS: Apple Speech (`SpeechAnalyzer`) as a 4th on-device Transcription Engine

**Date:** 2026-08-12 · **Scope:** Open Captions only · **Closes:** #53
**Related:** `docs/2026-08-12-macos-speechanalyzer-spike.md` (the availability-gating spike this
issue's acceptance criteria required before this proceeded), `docs/2026-08-12-macos-transcription-engine-selector.md`
(#35 — the three-way selector this extends to four), `docs/2026-08-12-coreai-parakeet-spike.md`
(#44 — the comparison-methodology reference; that spike's macOS 27+ SPM platform pin is the
harder case this issue's `if #available` gate avoids)

## Context

Apple's WWDC25 `Speech` framework overhaul (`SpeechAnalyzer` + `SpeechTranscriber`) is a
first-party, macOS 26+ on-device transcription API — a genuine candidate for a 4th
`MacTranscriptionEngineKind` alongside `.soniox`/`.nemotron`/`.parakeet`, usable for both live
capture and post-session re-transcription/import like Nemotron/Parakeet, not post-session-only
(unlike #47's Core AI Parakeet, which had no streaming path at all). The spike doc confirmed the
issue's core assumption — the whole feature gates behind a plain `if #available(macOS 26.0, *)`
inside the existing 14.4+-floor target, no deployment-target bump or plugin isolation needed.

## Decision

**A 4th `MacTranscriptionEngineKind` case, excluded below macOS 26 via a hand-written
`allCases`.** `CaseIterable` synthesis has no way to condition a case's presence on OS version, so
`allCases` is now a manual `static var` returning three or four cases depending on
`#available(macOS 26.0, *)`. The Settings picker's `ForEach(MacTranscriptionEngineKind.allCases)`
(`MacSettingsView.swift`) needed **zero** changes as a result — it already iterates whatever
`allCases` returns.

**Model-readiness abstracted behind a new shared protocol, not hardcoded to FluidAudio.**
`FluidAudioModelManager` was a concrete class with its own nested `Status` enum; `MacTranscriptionEngineKind.modelManager`
returned it directly. Apple Speech's asset lifecycle is a different mechanism entirely
(`AssetInventory`/`AssetInstallationRequest`, not FluidAudio), so `modelManager`'s return type
changed to `(any OnDeviceEngineModelManaging)?` — a new protocol (`modelTitle`, `status`,
`refreshStatus()`, `download()`) plus a shared `OnDeviceModelStatus` enum (the same five cases
`FluidAudioModelManager.Status` already had), both in a new
`Utility/OnDeviceModels/OnDeviceModelManaging.swift`. `FluidAudioModelManager` now conforms
directly (its own `Status` enum was deleted in favor of the shared one; a `modelTitle` computed
property forwards to its existing `Engine.modelTitle`). `MacOfflineDownloadControl` now takes
`manager: any OnDeviceEngineModelManaging` instead of the concrete FluidAudio type, so the same
view renders the download control for any of the three on-device engines without knowing which
backend is behind the current selection.

**`AssetInventory` has no synchronous status check — accepted as an inherent async gap, not
worked around.** Every other on-device readiness check in this codebase
(`FluidAudioModelLoader.isParakeetDownloaded()`/`isNemotronDownloaded()`) is a plain synchronous
file-existence check. `AssetInventory.status(forModules:)` is `async`. `AppleSpeechModelManager.refreshStatus()`
keeps the protocol's synchronous signature by firing a background `Task` and republishing
`status` once it resolves — callers read whatever was last cached, exactly like the FluidAudio
managers read a synchronous value, just staler. This means `MacTranscriptionViewModel.start()`'s
existing `manager.refreshStatus(); if manager.status != .ready { … }` pre-check (unchanged, works
identically via protocol dispatch) can theoretically see a stale cached value for Apple Speech
specifically — accepted rather than threading `async` through that call site, because
`SpeechAnalyzerTranscriberService.connectAndStart()` re-checks `AppleSpeechModelManager.shared.status == .ready`
itself before actually connecting (the exact same "sync pre-check + authoritative check-at-connect"
double-check pattern Parakeet/Nemotron already use — their `connectAndStart()` also re-checks
`FluidAudioModelLoader.isDownloaded()` even though `start()` already checked via `modelManager`).

**Live capture avoids `AnalyzerInputConverter` (macOS 27+, one version past this feature's
floor).** `SpeechAnalyzerTranscriberService` gets the analyzer's preferred format via
`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` and hand-converts each incoming 16 kHz
mono Float32 chunk with a plain `AVAudioConverter` — the same idiom `NemotronPostSessionEngine`
already uses for its own file-decode loop — before wrapping the result in an `AnalyzerInput`.
Results are consumed via `SpeechTranscriber.Result.isFinal`: each final result is its own new
segment (mirrors Parakeet's confirmed tier), each non-final (volatile) result replaces the
current partial — NOT the running full-transcript diffing Nemotron uses, since `Result.text` here
is per-result, not cumulative.

**Post-session uses the purpose-built whole-file path, with real per-word timestamps.**
`SpeechAnalyzerPostSessionEngine` needs no manual `AVAudioFile`/`AVAudioConverter` decode loop
(unlike `NemotronPostSessionEngine`, forced into one because FluidAudio exposes no URL-based
batch call for Nemotron): `SpeechAnalyzer.start(inputAudioFile:finishAfterFile:)` reads the whole
file, run concurrently (`async let`) with consuming `transcriber.results`. Passing
`attributeOptions: [.audioTimeRange]` when constructing the `SpeechTranscriber` gets a real
`CMTimeRange` per `AttributedString` run (via the `AttributeDynamicLookup` dynamic-member
subscript) — unlike Nemotron's post-session engine, which only has evenly-estimated timestamps
because Nemotron never reports per-word timing at all.

**Stale-selection fallback lives in one place.** `LiveSessionStore.transcriptionEngineKind`
(already the single choke point both `MacTranscriptionViewModel.start()` and
`RetranscriptionEngineKind.forCurrentMode` read through) now falls back to `.soniox` if the
decoded raw value is `.appleSpeech` but `#available(macOS 26.0, *)` no longer holds — the same
defensive shape as its existing unset/invalid-raw-value fallback. macOS doesn't downgrade in
normal use, so this is a low-risk edge case (per the issue's own framing), not a scenario expected
to fire in practice.

**Both factories need an unconditional `.appleSpeech` branch, wrapping the real construction in
`if #available`.** `MacTranscriptionEngineFactory.make` and `PostSessionRetranscriptionFactory.make`
both switch over an enum whose `.appleSpeech` case exists at compile time regardless of OS —
Swift's exhaustiveness check requires a branch unconditionally. Each branch checks
`#available(macOS 26.0, *)` and falls back to a Soniox engine in the `else` — reachable only in
the (already-guarded-against) stale-selection scenario above.

## What's new

- **`Utility/OnDeviceModels/OnDeviceModelManaging.swift`** — the shared `OnDeviceEngineModelManaging`
  protocol + `OnDeviceModelStatus` enum, described above.
- **`Utility/OnDeviceModels/AppleSpeechModelManager.swift`** — `@available(macOS 26.0, *)`,
  `@Observable @MainActor` singleton wrapping `AssetInventory`/`AssetInstallationRequest`.
- **`Services/Transcription/SpeechAnalyzerTranscriberService.swift`** — live-capture engine,
  described above.
- **`Services/Retranscription/SpeechAnalyzerPostSessionEngine.swift`** — post-session/import
  batch engine, described above.

## Files

- **New**: the four files above.
- `Services/Transcription/MacTranscriptionEngineKind.swift` — `.appleSpeech` case, hand-written
  `allCases`, `modelManager`'s return type, `MacTranscriptionEngineFactory.make`'s new branch.
- `Services/Retranscription/PostSessionRetranscriptionFactory.swift` — `RetranscriptionEngineKind.appleSpeech`
  case (`displayName`, `systemImage`, `isModelDownloaded` — now `@MainActor`-isolated —
  `forCurrentMode`), `PostSessionRetranscriptionFactory.make`'s new branch.
- `Utility/OnDeviceModels/FluidAudioModelManager.swift` — conforms to `OnDeviceEngineModelManaging`;
  its own nested `Status` enum removed in favor of the shared `OnDeviceModelStatus`; new
  `modelTitle` computed property.
- `Views/LiveTranscription/MacOfflineDownloadControl.swift` — `manager`'s type widened to the
  protocol existential.
- `Views/Settings/MacSettingsView.swift` — the two `manager.engine.modelTitle` reads become
  `manager.modelTitle` (the protocol requirement); no other changes (`selectedEngineReady`, the
  `ForEach`, and the footnote logic were already generic).
- `LiveSessionStore+TranscriptionEngine.swift` — the stale-selection fallback described above.
- `CLAUDE.md` — Project Overview and On-device STT sections.
- `docs/README.md` — this doc's row plus the spike doc's row.

## Unchanged on purpose

Diarization, term biasing, and AI summaries stay exactly as cloud-only as they were — all four
`isOnDevice`-keyed gating call sites (`MacSessionDetailView.autoSummarizeIfNeeded`, the
Re-summarize menu item's `.disabled`, the Summary tab's offline empty state,
`PostSessionRetranscriber`) already key off the generic `.isOnDevice` derivation
(`self != .soniox` on both enums), so `.appleSpeech` falls under them automatically — confirmed,
not re-implemented. Onboarding's binary Cloud-vs-Offline Mode step is untouched, matching the
precedent set when the three-way selector itself landed (#35) — it's a different question
(accuracy/privacy tradeoff) than the full engine picker.

## Follow-ups not taken

- **No locale picker.** Hardcoded `en-US`, snapped via `SpeechTranscriber.supportedLocale(equivalentTo:)`
  for robustness — matches the English-only ceiling Nemotron/Parakeet already have.
- **`AppleSpeechModelManager.refreshStatus()`'s async gap** (see Decision above) isn't threaded
  through `MacTranscriptionViewModel.start()`'s pre-check as a proper `async` call — accepted,
  since the authoritative check happens at `connectAndStart()` time regardless, matching the
  existing FluidAudio double-check pattern.
- **No accuracy/latency comparison** against Nemotron, Parakeet, or cloud Soniox — out of scope
  per this issue's own acceptance criteria (which asked for a gating spike, not a benchmark).

## Verification

Build the **OpenCaptions** scheme via the Xcode MCP (`BuildProject`) against this worktree's own
`OpenCaptions.xcodeproj` (not the main checkout's). This environment has no UI-automation tool for
a native macOS app's window (only browser-based tools are available), so the following are still
owed as manual verification:

1. On macOS 26+: Settings → General → Transcription Engine shows a 4th "Apple Speech (On-device)"
   option; selecting it with the asset not yet installed shows the Download control; downloading
   flips it to ready.
2. On macOS 26+: start a live session with Apple Speech selected — single-stream, no speaker
   labels, live partial text updates and finalizes as expected.
3. On macOS 26+: manually re-transcribe a saved session with Apple Speech selected — real
   per-word timestamps (not evenly estimated, unlike Nemotron).
4. Confirm the Re-summarize menu item, Summary tab empty state, and `autoSummarizeIfNeeded` all
   treat an Apple-Speech-captured session as on-device (no auto-summary; switching to Soniox and
   re-summarizing manually still works).
5. On a Mac below macOS 26 (or by temporarily forcing the `#available` check to fail): the picker
   shows only three options, and manually setting the UserDefaults raw value to `"appleSpeech"`
   falls back to Soniox on next read rather than crashing.
