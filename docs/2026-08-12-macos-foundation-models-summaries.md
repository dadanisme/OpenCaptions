# macOS: on-device summaries via Apple Foundation Models

**Date:** 2026-08-12 · **Scope:** Open Captions only · **Closes:** #45
**Related:** `docs/2026-08-04-macos-openrouter-summaries.md` (superseded's "no provider
abstraction" framing — the OpenRouter transport itself is untouched), `docs/2026-08-12-macos-transcription-engine-selector.md`
(the Settings-picker + readiness-gating pattern this mirrors), `docs/2026-08-12-coreai-parakeet-spike.md`
(the other macOS-27+-gated spike landed the same day)

## Context

Summaries had exactly one provider — OpenRouter, pinned, no picker
(`docs/2026-08-04-macos-openrouter-summaries.md` explicitly called a model picker out
of scope). Apple's Foundation Models framework exposes the on-device model behind
Apple Intelligence directly to apps (`import FoundationModels`, macOS 26+): no API
key, no network call, no per-request cost, data never leaves the device — a natural
fit for this app's existing "no backend, bring-your-own-key" philosophy and its
on-device transcription precedent (Nemotron/Parakeet via FluidAudio).

This dev machine runs **macOS 27.0 / Xcode 27.0 (beta)**, so this was verified against
the actual installed SDK rather than guessed from documentation:
`/Applications/Xcode-beta.app/.../MacOSX.sdk/.../FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
was read directly to confirm the exact public API surface below — the framework
expanded at WWDC26, after this assistant's own knowledge cutoff, so nothing here was
taken on faith.

## Decisions

**1. Summary availability is decoupled from the Transcription Engine setting
entirely.** Before this change, all four summary gates (auto-summarize, Re-summarize,
the Summary tab empty state, post-retranscription regen) keyed off
`MacTranscriptionEngineKind.isOnDevice` — selecting an on-device *transcription*
engine blocked *any* summary, even though summarization has no real dependency on how
the transcript was captured. That coupling was always just a stale proxy from before a
real summary-provider preference existed, and a known papercut: users had to switch
Transcription Engine just to unlock a summary. The new `SummaryProviderKind` preference
(`LiveSessionStore+SummaryProvider.swift`) is now the *only* thing any of the four
gates read: OpenRouter is attempted unconditionally (a missing key or network failure
still surfaces as a runtime `SessionSummaryError`, exactly as before), and
`.foundationModels` is gated purely on `SystemLanguageModel.default.isAvailable`.

**2. Context-window overflow refuses with a clear error — no truncation, no
chunk-and-reduce.** `ConversationFormatter.buildTranscript` feeds the entire transcript
in one call, uncapped, both before and after this change. `callFoundationModelsAPI`
attempts the call as-is; when the framework reports the context was exceeded, it
throws `SessionSummaryError.onDeviceContextExceeded(detail:)` (copy: "Switch to
OpenRouter…"), rather than proactively guessing a token budget and cutting content —
a simpler behavior than the alternative, and one that never risks silently returning a
summary of only part of the session. `detail` names the actual measured size where a
number is available, so the error reads e.g. "This session is too long to summarize
on-device (5,412 tokens, over the 4,096-token on-device limit)." rather than a bare
refusal — see `contextOverflowDetail` in the **What's new** section below for where
that number comes from and the narrow OS range where it can't be measured.

**3. Speaker auto-naming reuses the exact same schema/pipeline on-device, with zero
special-casing.** `OnDeviceSummary`'s `speakers` field mirrors `SummaryAPIResponse`'s
1:1, and `SpeakerNameResolver`/`SpeakerRenamer` are unaware which transport produced
the identifications. A transcript only carries "Speaker N" labels when the underlying
*transcription* was diarized (Soniox) — the existing prompt already instructs the
model never to name an id that isn't in the transcript's roster, so a session
transcribed on-device (no diarization) naturally yields no `speakers` field regardless
of which model summarizes it. No new gating logic needed.

## What's new

- **`Services/SummaryProviderKind.swift`** — the two-way enum (`openRouter` /
  `foundationModels`), mirroring `MacTranscriptionEngineKind`'s shape but with an
  `isAvailable`/`unavailableReason` pair instead of a `modelManager` — there's no
  download step; the OS manages Apple Intelligence's own model.
- **`LiveSessionStore+SummaryProvider.swift`** — the preference key/accessor, no
  migration needed (brand-new key, default `.openRouter`).
- **`Services/SummaryService+FoundationModels.swift`** — the transport. A
  `@Generable` `OnDeviceSummary` (+ nested `OnDeviceSpeakerIdentification`/
  `OnDeviceSpeakerCandidate`) mirrors `SummaryAPIResponse`'s fields, with `@Guide`
  descriptions ported from `SummaryService+Schema.swift`'s own doc comments — no
  forked prompt; `SummaryService.systemInstruction(language:)` is reused verbatim as
  the session's instructions.
- **`SpeakerPredictions.init(identifications:)`** (added to
  `Services/Speakers/SpeakerIdentification.swift`) — a direct constructor alongside
  the existing lenient `init(from:)`. The lenient decoder exists to protect against a
  malformed *raw JSON* response; guided generation has no such failure mode (the
  framework enforces the schema during generation), so the on-device path never needs
  that protection and shouldn't fake going through it.
- **`contextOverflowDetail(for:transcript:)`** (`SummaryService+FoundationModels.swift`)
  — the token count shown alongside `.onDeviceContextExceeded`. Two sources, in
  preference order, since the count isn't available the same way on every OS version:
  macOS 27+'s `LanguageModelError.contextSizeExceeded` already carries the exact
  `tokenCount`/`contextSize` for the failed attempt, no extra work; macOS 26.4–26.x's
  deprecated `GenerationError` carries no structured numbers at all, so that range
  falls back to an independent `SystemLanguageModel.tokenCount(for: transcript)` call
  (itself gated `@available(macOS 26.4, *)` — a **point-release** API, later than this
  feature's 26.0 floor) to measure the transcript alone. Below 26.4, neither source
  exists and the error falls back to its plain, count-less copy.

## A real API-versioning trap, caught by reading the actual SDK interface

The framework's context-overflow error type **changed between macOS 26 and 27**:
`LanguageModelSession.GenerationError.exceededContextWindowSize` (macOS 26) was
deprecated in macOS 27 in favor of a new unified `LanguageModelError.contextSizeExceeded`
— but `LanguageModelError` itself is `@available(macOS 27, *)`; it didn't exist as a
type before 27. Since this feature's own floor is macOS 26 (per the issue), an
exact-macOS-26.0 runtime can only ever throw the deprecated `GenerationError` — the
replacement type isn't there yet. `SummaryService+FoundationModels.swift` therefore
checks **both**: `LanguageModelError.contextSizeExceeded` under `#available(macOS 27,
*)`, falling back to `GenerationError.exceededContextWindowSize` for exactly-26
runtimes. The deprecated reference is isolated in its own tiny
`@available(macOS, deprecated: 27.0, …)`-annotated function — Swift doesn't warn about
a deprecated symbol referenced from another declaration deprecated on the same
platform/version, so this is the one intentional, silenced warning-source in the file,
not an oversight.

Also confirmed from the interface directly (rather than the issue's own citations,
which mentioned a "region unsupported" reason that doesn't actually exist as a case):
`SystemLanguageModel.Availability.UnavailableReason` has exactly three cases —
`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` — mapped to
Settings copy in `SummaryProviderKind.unavailableReason`, with an `@unknown default`
since `UnavailableReason` isn't `@frozen` (Apple could add a case in a future OS
without that being a source break).

A second, smaller version split: `SystemLanguageModel.tokenCount(for:)` — the public
tokenizer call `contextOverflowDetail` falls back to for the macOS-26-vintage error —
is itself gated `@available(macOS 26.4, *)`, a **point release**, not the 26.0 this
feature otherwise floors at. So there's a narrow real gap (exact macOS 26.0–26.3) where
neither error type carries a count and no independent tokenizer call exists either —
the error falls back to its plain copy there, by necessity, not an oversight.

## Not yet empirically verified

The SDK's public interface was read directly and is authoritative for **shape**
(types, methods, error cases), but no live `LanguageModelSession` call had actually
been run against a real transcript as of this note — that needs the Xcode MCP pointed
at this worktree's project (a build-environment prerequisite, not a code question).
Follow-up once that's available:
- The transcript length at which `contextSizeExceeded`/`exceededContextWindowSize`
  actually fires in practice (the issue cites a fixed 4096-token window across
  instructions + input + output combined, but the *effective* budget for a transcript
  depends on how much `systemInstruction(language:)` itself consumes).
- Output-quality comparison against a live OpenRouter call on the same transcript.
- Whether `systemInstruction(language:)`, reused verbatim, needs trimming for the
  on-device budget — if it does, the trimmed variant needs its own entry here, not a
  silent fork.

## Verification

- `BuildProject` via Xcode MCP against this worktree — confirms the `@available(macOS
  26, *)` gating compiles clean at the unchanged 14.4 deployment target, and confirms
  which warnings (if any beyond the one documented deprecation reference above) show up.
- Settings → General → Summary Model: OpenRouter always shows no reason row; Foundation
  Models shows a reason row unless Apple Intelligence is actually on for this Mac.
- Generate a summary with each provider on a real saved session; confirm both render
  identically in the Summary tab.
- Switch Transcription Engine to Nemotron/Parakeet; confirm OpenRouter summaries still
  work (decoupling verified) and Foundation Models still gates purely on its own
  availability.
- Run a very long session through Foundation Models; confirm `onDeviceContextExceeded`'s
  copy surfaces instead of a crash/hang, note the actual transcript length that
  triggered it here, and confirm the reported token count (this dev machine is macOS
  27, so the `LanguageModelError.contextSizeExceeded` path — exact counts, no tokenizer
  fallback needed) reads sensibly against that transcript's actual length.
