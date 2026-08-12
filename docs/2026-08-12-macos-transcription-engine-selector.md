# macOS: three-way Transcription Engine selector (Soniox/Nemotron/Parakeet)

**Date:** 2026-08-12 · **Scope:** Open Captions only · **Closes:** #35
**Related:** `docs/2026-08-12-coreai-parakeet-spike.md` (#44 — the spike this issue's
description named as a possible prerequisite; recommended deferring Core AI, so
this lands entirely on the existing FluidAudio engines), `docs/2026-07-10-macos-on-device-engines.md`
(the original 3-way picker and engine implementations — stays current),
`docs/2026-07-10-macos-offline-mode.md` (the binary toggle this replaces — now
historical)

## Context

"Offline Mode" was a single global boolean, but it wasn't a clean binary even
internally: live capture always ran Nemotron when it was on
(`MacTranscriptionViewModel.swift`), while post-session re-transcription and file
import always ran Parakeet (`PostSessionRetranscriptionFactory.swift`) — the user
never actually chose which on-device model ran, and each context was stuck with
the other's engine unavailable. This replaces the toggle with an explicit
three-way model selector (Soniox/Nemotron/Parakeet) as a global Settings
preference, wired into both live capture and post-session/import so the choice
is consistent everywhere.

Landed after #33 (account/guest-mode removal) and #37 (runtime API keys), per
the issue's own note that the two should land in that order — the guest-mode
force-set of the old key it flagged is confirmed gone; there was nothing left to
update there.

## Decision

**`MacTranscriptionEngineKind` already had everything needed.** It was a real
user-facing picker before the binary toggle collapsed it (`2026-07-10-macos-on-device-engines.md`)
— all three cases, `displayName`, `isOnDevice`, `modelManager`, and the live
factory (`MacTranscriptionEngineFactory.make`) already built a `Parakeet`
engine for live use. Re-exposing it as the picker's `selection` type needed
zero enum changes.

**New key, not a repurposed one.** `LiveSessionStore.offlineModeKey`
(`"opencaptions.offlineMode.enabled"`, `Bool`) is deleted outright, replaced by
`LiveSessionStore.transcriptionEngineKindKey`
(`"opencaptions.transcriptionEngine.kind"`, `String` — `MacTranscriptionEngineKind.rawValue`,
default `"soniox"`). Both live in a new `LiveSessionStore+TranscriptionEngine.swift`
extension file rather than growing the already-over-budget `LiveSessionStore.swift`
(422 lines before this, per CLAUDE.md's own flagged debt) — the split this repo's
conventions call for. **Migration**: `LiveSessionStore.migrateOfflineModeKeyIfNeeded()`,
called once from `OpenCaptionsApp.init()` before `register(defaults:)`, maps an
existing `true` → `.nemotron` (the old toggle's sole on-device engine), `false`/unset
→ `.soniox`, then deletes the legacy key. No-ops once the new key has any value,
so it's safe to call unconditionally on every launch.

**Post-session gets a real three-way selector too — `RetranscriptionEngineKind`
gained a `.nemotron` case** (it previously had only `.parakeet`/`.soniox`,
since post-session/import always followed the live toggle's *opposite* engine).
`forCurrentMode` now switches over `LiveSessionStore.transcriptionEngineKind`
directly (soniox→soniox, parakeet→parakeet, nemotron→nemotron) instead of a
bool ternary. This needed a new `NemotronPostSessionEngine` — FluidAudio's
`StreamingNemotronAsrManager` exposes no URL-based batch call (unlike Parakeet's
`AsrManager.transcribe(audioURL:)`), so it's the first post-session engine in
this codebase that does its own file decode: `AVAudioFile` + `AVAudioConverter`
to 16 kHz mono Float32 (mirroring the live-capture conversion pattern in
`MacAudioService`/`MixedAudioCaptureService+Mic.swift` — including their
`supplied`-flag exhaustion guard on the converter's input block, needed here
too since a naive unconditional-`.haveData` block risks the converter
re-consuming the same input buffer and duplicating audio), fed a few seconds
at a time into `process(audioBuffer:)` (which buffers and re-chunks
internally — buffers handed to it don't need to be pre-sliced), then
`finish()` for the tail. Nemotron reports only the running full transcript,
never per-word timings, so the final string is split into one
`PostSessionToken` **per word** (leading space, matching the Soniox/Parakeet
convention) with timestamps evenly distributed across the file's duration —
coarse, not measured, but enough for it to end up as multiple tokens rather
than one: `PostSessionSegmentBuilder`'s punctuation/word-count splitting only
fires *between* tokens, so a first draft that returned the whole transcript as
a single token produced one unreadable wall-of-text line per re-transcription
(caught in review, fixed before landing).

**Per-model download gating, not "both before selectable."**
`FluidAudioModelManager` was already fully per-model (two independent
`@Observable` singletons, each own `Status`) — the "both must be `.ready`"
coupling was purely UI-layer (`MacSettingsView.offlineFilesReady`,
`MacOfflineDownloadControl` treating `[.nemotron, .parakeet]` as one download
unit). `MacOfflineDownloadControl` now takes a single `manager:` and the
Settings row shows it only for the *currently selected* on-device engine,
below the picker (which stays interactive throughout — switching back to
Soniox, or to an already-downloaded engine, needs no extra step).

**Onboarding stays a binary Cloud-vs-Offline choice, by design — not touched
beyond the key it writes.** The Mode step's "cloud accuracy vs. on-device
privacy" framing is a different question than the full three-way picker
(#35's own Context section: "the selector is a global Settings preference,"
not a redesign of onboarding), so `MacOnboardingModeStep`/`MacOnboardingDownloadStep`
keep their existing copy and still download both models together. Only
`MacOnboardingView.complete()` changed: it now writes `.nemotron`/`.soniox` to
the new key instead of a raw bool to the old one — offline still maps to
Nemotron, the same engine the old toggle ran live.

**Gating call sites keyed off `isOffline` stay `isOffline` — just redefined.**
Both `MacSettingsView` and `MacSessionDetailView` add a tiny
`private var isOffline: Bool { selectedEngine.isOnDevice }` next to their new
`@AppStorage(transcriptionEngineKindKey)` binding, so the three existing
call sites per file (`.disabled(isOffline)`, `guard !isOffline`, `if isOffline`)
needed no changes at all — only the property's *definition* moved from a raw
Bool `@AppStorage` to a derived one. Per #35's own scope: no change to *what*
is gated (diarization/term-biasing/summaries stay cloud-only) — only what
triggers the gate.

## What's new

- **`LiveSessionStore+TranscriptionEngine.swift`** — the new key, the
  `transcriptionEngineKind` computed accessor, and the migration function.
  Both the key and the accessor are `nonisolated` — `LiveSessionStore` is
  `@MainActor`, but `RetranscriptionEngineKind.forCurrentMode` (a plain,
  non-isolated static var, read from several non-MainActor-guaranteed call
  sites) needs to read them without crossing an actor boundary, exactly as the
  old raw `UserDefaults.standard.bool(forKey: LiveSessionStore.offlineModeKey)`
  read did implicitly.
- **`Services/Retranscription/NemotronPostSessionEngine.swift`** — described
  above.
- **`MacOfflineDownloadControl`** — rewritten from a hardcoded
  `[.nemotron, .parakeet]` array to a single `manager: FluidAudioModelManager`
  parameter (its only call site, so no compatibility shim needed).

## Files

- **New** `LiveSessionStore+TranscriptionEngine.swift`,
  `Services/Retranscription/NemotronPostSessionEngine.swift`.
- `OpenCaptionsApp.swift` — migration call + `register(defaults:)` key swap.
- `LiveSessionStore.swift` — `offlineModeKey` removed.
- `Services/Transcription/MacTranscriptionEngineKind.swift` — header comment
  only (no code change — the enum was already complete).
- `ViewModel/MacTranscriptionViewModel.swift` — `start()`'s engine resolution.
- `Services/Retranscription/PostSessionRetranscriptionFactory.swift` —
  `RetranscriptionEngineKind.nemotron` case, `isOnDevice`/`isModelDownloaded`
  helpers, `forCurrentMode`, factory branch.
- `Services/Retranscription/PostSessionRetranscriber.swift` — summary-skip
  keys off the passed `kind` instead of re-reading global state.
- `Services/Retranscription/PostSessionTranscriptionEngine.swift` — header
  comment + `.modelNotDownloaded` copy.
- `Views/Settings/MacSettingsView.swift` — the picker replaces the toggle;
  `isOffline`/`selectedEngineReady`/footnote copy.
- `Views/LiveTranscription/MacOfflineDownloadControl.swift` — per-model
  rewrite.
- `Views/SessionDetail/MacSessionDetailView.swift` — `isOffline` redefinition.
- `Views/SessionDetail/MacSessionDetailView+Retranscription.swift` — engine-generic
  `isOnDevice`/`isModelDownloaded` instead of hardcoded `== .parakeet` checks.
- `Views/Onboarding/MacOnboardingView.swift`,
  `MacOnboardingModeStep.swift`, `MacOnboardingDownloadStep.swift` — key
  write + cross-reference copy only.
- `ViewModel/FileImportManager.swift`, `ViewModel/RetranscriptionManager.swift`
  — their pre-run model-availability guards were initially left hardcoded to
  `kind == .parakeet` (missed the new `.nemotron` case entirely — caught in
  review, not at authoring time), now `!kind.isModelDownloaded`.
- Cross-reference copy only (no logic change): `Views/Common/SessionSpeakersLine.swift`,
  `Views/Vocabulary/VocabularyScreen.swift`, `Services/SummaryService+OpenRouter.swift`.
- `CLAUDE.md` — Project Overview, On-device STT, Custom vocabulary, Metering,
  and App shell sections updated.
- `docs/2026-07-10-macos-offline-mode.md` — marked historical.

## Unchanged on purpose

Diarization, term biasing, and AI summaries stay exactly as cloud-only as they
were — this issue only changes what UI/preference *triggers* the existing
gates, never what they gate. Onboarding's binary Mode step and "download both
models together" behavior are untouched (see Decision above). `FluidAudioModelLoader`
itself needed no changes — its per-engine download/check/load functions were
already independent; only the UI layer combined them.

## Follow-ups not taken

- **Onboarding still downloads both models for the offline path**, even though
  its choice only ever needs Nemotron live. Parakeet ends up pre-downloaded as
  a side effect (handy if the user later switches to it in Settings, or uses
  re-transcription), but a strict reading of "only download what's needed"
  would trim this. Out of scope per #35's decided scope (Context: onboarding
  wasn't part of the selector redesign).
- **No per-word timestamps for Nemotron post-session re-transcription** — see
  Decision above. Matches Nemotron's existing live characteristics
  (`providesReliableTimestamps == false`); adding them would need FluidAudio
  to expose token-level timing for the streaming manager, not something this
  issue's scope depends on.
- **No accuracy/latency comparison between Nemotron and Parakeet** in either
  newly-cross-wired context (Nemotron post-session, Parakeet already-worked-but-newly-user-selectable
  live) — #35 is about exposing the existing engines symmetrically, not
  benchmarking them against each other.

## Verification

Build the **OpenCaptions** scheme via the Xcode MCP (`BuildProject`) — clean,
zero new warnings. Launched via `RunProject`; console showed only generic
macOS system-log noise (CoreSpotlight donation/indexing failures — unrelated to
this change), no crash. This environment has no UI-automation tool for a
native macOS app's window (only browser-based tools are available), so the
picker itself was **not** click-tested interactively — that verification is
still owed manually:

1. Settings → General: the old Offline Mode toggle is gone; a "Transcription
   Engine" section shows a three-option picker.
2. Selecting Nemotron or Parakeet with its model not yet downloaded shows the
   Download control below the picker; downloading flips it away once `.ready`.
3. Start a live session with each of the three selected; confirm the right
   engine actually runs (on-device: single-stream, no speaker labels; Soniox:
   diarized).
4. Manually re-transcribe a saved session under each of the three selections;
   confirm Nemotron's new post-session path produces a sensible transcript
   (no per-word timestamp precision expected — see Decision).
5. Fresh install vs. an existing `true`/`false` `opencaptions.offlineMode.enabled`
   value (set manually via `defaults write`) — confirm the migration lands on
   `.nemotron`/`.soniox` respectively and the legacy key is gone afterward.
6. Onboarding's offline path still completes and lands on Nemotron.
