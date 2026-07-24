# macOS Post-Session Re-Transcription (pluggable protocol)

**Date:** 2026-07-16
**Target:** Open Captions (standalone macOS app) only.

## Context

A live/realtime STT pass must emit text incrementally with limited look-ahead, so it
is inherently less accurate than a batch/async pass that sees the whole recording.
Open Captions already persists each session's audio (`Application Support/SessionAudio/<uuid>.m4a`,
referenced by `TranscriptionSession.audioFileName` — see
`docs/2026-07-08-macos-session-audio-playback.md`), so we can **re-transcribe a finished
session** for higher accuracy without re-recording.

This feature adds a pluggable **post-session** engine platform mirroring the live
`RealtimeTranscriptionEngine` platform (`docs/2026-06-24-transcription-engine-abstraction.md`),
plus a manual trigger and an automatic-after-recording option.

## Decisions

1. **Two backends now, pluggable for more.**
   - **`parakeet`** — on-device FluidAudio `AsrManager` batch decode over Parakeet TDT v2
     (`parakeet-tdt-0.6b-v2`, already downloaded/load-wired via `FluidAudioModelLoader`).
     Offline, free, English-only, **no diarization** (single unlabeled stream).
   - **`soniox`** — cloud Soniox `stt-async-v5` REST (upload → create → poll → fetch →
     delete). Diarized, multi-language, **billable** (same `SONIOX_API_KEY`).
2. **Replace in place + re-summarize.** A run overwrites the session's `TranscriptionLine`s,
   clears the now-stale summary, and regenerates it (cloud; skipped in Offline Mode). The
   manual path confirms first (it discards the original text + any edited speaker names).
3. **No engine choice — it follows Offline Mode.** There is no re-transcription engine
   picker. The engine is `RetranscriptionEngineKind.forCurrentMode`: **Parakeet** when
   Offline Mode is on, **Soniox** when it's off. This applies to both the manual and the
   automatic paths, so re-transcription behaves like the live pipeline the user already chose.
4. **Billing: metered like a live session.** The cloud engine deducts `ceil(minutes)` of
   the recording's duration, gated on balance; the manual path shows the paywall, the
   automatic path silently skips when the balance is insufficient. Parakeet is always free.
5. **Two gates.** A remote feature flag `Mac_post_session_retranscription`
   (`FeatureFlag.postSessionRetranscription`, default **OFF** — dark rollout) is the master
   switch; a per-device Settings **toggle** (`LiveSessionStore.retranscriptionAutoKey`, Bool,
   default off) enables **automatic** re-transcription after each recording. The manual
   ⋯-menu trigger is gated by the remote flag alone (no separate per-device toggle).
6. **Offline diarization loss is accepted, warned.** Re-transcribing a diarized (Soniox)
   session with Parakeet collapses it to one unlabeled speaker; the confirmation dialog
   warns. (Sessions recorded in Offline Mode were already single-stream, so no loss there.)

## The protocol

`PostSessionTranscriptionEngine` (`OpenCaptions/Services/Retranscription/`) is one-shot/batch —
it takes a finished audio file and returns the full ordered token list in a single async
call (vs. the streaming `RealtimeTranscriptionEngine`):

```swift
protocol PostSessionTranscriptionEngine: AnyObject {
    var capabilities: PostSessionEngineCapabilities { get }
    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken]
}
```

- `PostSessionToken { text, speaker (-1 = none), startMs, endMs }` — engine-agnostic.
- `PostSessionSegmentBuilder` groups tokens into `TranscriptionLine`-shaped rows using the
  **same** speaker/sentence/word-cap rules as the live accumulator (shared via
  `SentenceHeuristics`), so a re-transcribed transcript reads like a recorded one.
- Implementations must honor cooperative cancellation and report `PostSessionProgress`.

### Adding a provider

1. Add a `PostSessionTranscriptionEngine` conformer.
2. Add a `RetranscriptionEngineKind` case + a `PostSessionRetranscriptionFactory.make` branch
   (set `isMetered` / `supportsDiarization`).
3. If it needs setup (model download / key), gate the menu item accordingly.

## Flow / key files

- Engines: `ParakeetPostSessionEngine`, `SonioxAsyncPostSessionEngine` (+`+Requests`).
- Shared core: `PostSessionRetranscriber.run(...)` — runs the engine, replaces the
  transcript, meters the cloud engine, regenerates the summary. Used by **both** paths.
- Runs are owned by `RetranscriptionManager` — an **app-lifetime `@Observable @MainActor`
  singleton**, so a run **survives leaving/closing the detail window** (no more "keep this
  window open"). One per-session in-flight registry (keyed by `PersistentIdentifier`) serves
  BOTH paths, so manual + automatic can't overlap and double-run the same recording.
- Manual: `MacSessionDetailView+Retranscription` (⋯-menu → confirm → **non-blocking**
  `RetranscriptionProgressBanner` → paywall). The banner reappears if you return mid-run.
- Automatic: `RetranscriptionManager.startAutomatic(...)` fired from
  `MacTranscriptionViewModel.stop()` after save (background, no UI, no paywall). Engine =
  `RetranscriptionEngineKind.forCurrentMode`.
- Billing safety: the metered window is a **reference count** on `MacSubscriptionManager`
  (a live session + a re-transcription can overlap without clearing each other's window),
  and the cloud path gates on the **whole estimated cost** up front (`canAfford(minutes:)`),
  since a batch job can't pause at zero like a live session can.
- Gating: `FeatureFlag.postSessionRetranscription`, `LiveSessionStore.retranscriptionAutoKey`
  (Bool auto toggle), Settings toggle in `MacSettingsView`.

## Shared links

Re-transcription keeps a shared session's link consistent. After the transcript is
replaced, `SessionLinkSharer.resyncShared(session:)` → `FirestoreSyncService.resyncSharedSession(...)`
re-pushes the new lines to the **same** `cloudSessionId` (same public URL) via the existing
`writeSessionDocs` writer: it overwrites line docs `0..<count` and resets `lineCount` (the web
reads by `lineCount`, so a now-shorter transcript's orphaned trailing docs are ignored), and
patches the `speakers` map. The summary is re-mirrored by the regeneration step (online) or
left cleared on the web (offline) — matching local state. Password protection is server-owned
and untouched. All no-ops when the session is unshared or `sessionSharing` is off.

## UI indicator

The session list (`TranscriptionsScreen.sessionRow`) shows a spinner + "Re-transcribing…"
while a run is in flight (observes `RetranscriptionManager`), and the detail screen shows the
non-blocking banner — both for the manual and automatic paths.

## Trade-offs / follow-ups

- The stored `.m4a` is **lossy AAC (32 kbps, 16 kHz mono)**, not the original PCM — the
  ceiling on accuracy is the compressed audio.
- Re-syncing a shorter transcript leaves **orphaned trailing line docs** in Firestore
  (harmless — ignored by the `lineCount`-bounded web read; a minor storage cost).
- **Cloud auto** re-bills every recording (the live cloud pass already charged) — the
  Settings copy warns; users opt in explicitly.
- Localization: macOS UI strings remain hardcoded English (no `LanguageManager`).
