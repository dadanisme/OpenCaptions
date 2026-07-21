# macOS MVP — Standalone App (Issue #171)

**Date:** 2026-07-04
**Status:** Implemented (branch `feature/macos-mvp-171`); pending on-device verification.
**Parent epic:** #103

## Decision

The first native macOS deliverable (#171) is built as a **fully standalone target
(`OpenCaptions/`) that shares NO source with the iOS `unmute` target.** Everything the
Mac app needs is either copied-and-adapted from `unmute/` or written fresh under
`OpenCaptions/`.

This **overrides the issue's original "shares Model/Services/ViewModel" wording** —
the product owner chose standalone during implementation.

### Why standalone (vs. shared code + `#if os(iOS)` guards)

- **Zero risk to iOS.** No `unmute/` file is touched, so the iOS target builds and
  runs exactly as before — the acceptance criterion "iOS still builds unchanged" is
  satisfied by construction, not by careful guarding.
- **No fragile project surgery.** The project uses Xcode 16 synchronized folder
  groups (`PBXFileSystemSynchronizedRootGroup`). Sharing `unmute/` into a second
  target means hand-editing membership exception sets — fragile. Standalone avoids it
  entirely: files dropped under `OpenCaptions/` are auto-compiled into the target.
- **No dependencies.** A standalone minimal Soniox app needs only system frameworks
  (SwiftData, AVFoundation, Foundation/URLSession). **No Firebase, no RevenueCat, no
  SPM.** Summarization is a plain `URLSession` POST with a bearer token, so it needs
  no backend SDK.

### Accepted trade-off

The Soniox `URLSessionWebSocketTask` client and the token/diarization accumulation
logic are **duplicated** across iOS and Mac and can drift. This is the deliberate
price of a clean, independently-evolving Mac app for a minimal first cut (#172+).

## Scope

**In (the flow):** launch → record → live Soniox transcript *with speaker
diarization* → save to local SwiftData history → generate AI summary.

**Deferred to a follow-up sub-issue under #103:** Sign in with Apple / auth,
subscription & minute-billing gating, Firestore share-to-web + Analytics, Live
Activity, on-device engines, and TTS. Sessions save with `userId == nil`; the Mac
history lists all local sessions.

## What was copied vs. written fresh

**Copied-and-adapted** (macOS-clean as-is; adaptations noted):
- Models: `TranscriptionToken`, `TranscriptionSession`(+`Derived`),
  `TranscriptionLine` (carries `TimeRange`), `ActionItem`, `TranscriberModel`
  (+`Persistence` — `saveSession` sets `userId: nil`), `SonioxConfig`,
  `TranscriptionError` (`ConnectionState`/`TranscriptionServiceError`).
- Soniox engine: `RealtimeTranscriptionEngine`, `OnlineTranscriberService`
  (+`Messages`,+`ConnectionHealth`), `SonioxSecrets`, `TranscriptionConstants`.
- Summary: `SummaryService` (dropped `AnalyticsService`; language hardcoded to
  "English"), `SummaryViewModel` (dropped the `FirestoreSyncService.writeSummary`
  mirror), `ConversationFormatter`.

**Written fresh for macOS:**
- `MacAudioService` — `AVAudioEngine` input tap → `AVAudioConverter` → 16 kHz mono
  Float32 `AsyncStream`, with **no `AVAudioSession`** (macOS has none) and mic access
  via `AVCaptureDevice.requestAccess(for: .audio)`. The DSP pipeline is identical to
  the iOS `configureEngineAndTap` (which already reads the device input format
  dynamically), so only the session/interruption layer was dropped.
- `MacTranscriptionViewModel` (+`Accumulator`) — distilled from `OnlineViewModel`:
  the diarization-on token→bubble accumulation (sentence flush, word/paragraph
  limits, CJK-safe boundaries) ported verbatim, minus Firestore/Live Activity/
  subscription/reconnection/periodic-reset. Instantiates the Soniox engine directly
  (no multi-engine factory).
- UI: `OpenCaptionsApp` (schema container, no Firebase), `ContentView`
  (`NavigationSplitView` list + detail), `MacLiveTranscriptionView` (record/stop +
  live transcript), `MacSessionDetailView` (summary + transcript).

## Build settings (`OpenCaptions` target)

- `MACOSX_DEPLOYMENT_TARGET = 14.0` (was 26.5; issue floor + SwiftData).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (was `MainActor`) — the ported
  non-`@MainActor` engine/protocol assume the iOS concurrency model.
- **Entitlements via `OpenCaptions.entitlements`** (repo root, `CODE_SIGN_ENTITLEMENTS`):
  `com.apple.security.app-sandbox`, `.device.audio-input`, `.network.client`.
  `.device.audio-input` alone authorizes the whole capture path (plain `AVAudioEngine`
  mic tap *and* the Core Audio process-tap system-audio path). **Historical note /
  correction:** early builds also carried a `temporary-exception.mach-lookup.global-name`
  for **`com.apple.audioanalyticsd`**, believed necessary to stop an `AVAudioEngine`
  `PRECONDITION FAILURE`. That was a misdiagnosis — `audioanalyticsd` is an opt-in
  telemetry daemon *not* on the capture path (a denied lookup is a benign logged EPERM,
  not an abort; the base sandbox profile's `(coreaudio-services)` macro already allows
  it), and the real crash (`AttachNode: required condition is false: node != nil`) was
  the mic being unavailable when `inputFormat` is read — fixed by `.device.audio-input`
  + gating mic permission before start (and now a `channelCount/sampleRate > 0` guard in
  `MacAudioService` / `MixedAudioCaptureService+Mic`). The exception was **removed** in
  `fix/remove-audioanalyticsd-entitlement` because the Mac App Store rejects it under
  Guideline 2.4.5(i).
- `INFOPLIST_KEY_NSMicrophoneUsageDescription` (a known key — merges into the
  generated Info.plist fine).
- **API keys via a dedicated `OpenCaptions-Info.plist`** (repo root), mirroring the original iOS
  target's Info.plist: it holds `SONIOX_API_KEY = $(SONIOX_API_KEY)` and
  `SUMMARIZE_API_TOKEN = $(SUMMARIZE_API_TOKEN)`, set via `INFOPLIST_FILE =
  "OpenCaptions-Info.plist"` alongside `GENERATE_INFOPLIST_FILE = YES` (Xcode merges the
  file's `$(VAR)` keys with the generated keys). `Config.xcconfig` is project-level,
  so `$(VAR)` resolves for the Mac target.
  - **Why not `INFOPLIST_KEY_SONIOX_API_KEY`:** `GENERATE_INFOPLIST_FILE` only emits
    a *known allowlist* of `INFOPLIST_KEY_*` names; arbitrary custom keys are silently
    dropped, so `SonioxSecrets` `fatalError`ed at launch. The file-based approach is
    the fix.

`scripts/check-file-length.sh` now also scans `OpenCaptions/`.

## Verification (physical Mac required)

1. iOS target builds & runs unchanged (no `unmute/` files touched).
2. `OpenCaptions` builds; launches in a resizable window on macOS 14+.
3. Record → mic prompt → live Soniox transcript with speaker labels.
4. Stop → session saved, listed, and reopens with its transcript.
5. Summarize → AI summary persisted.
