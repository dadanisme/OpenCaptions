# macOS: Import audio & video files for transcription

**Date:** 2026-07-16
**Target:** OpenCaptions (standalone macOS app).
**Depends on:** the post-session re-transcription platform, which shipped the
`PostSessionTranscriptionEngine` stack.

## Context

OpenCaptions could only transcribe **live** mic/system audio. Users often already have
recordings — meeting captures, voice memos, lecture videos — with no way to bring them
in. This adds a file-import entry point that ingests an existing audio **or video** file,
extracts/normalizes its audio, transcribes it, and saves a normal `TranscriptionSession`
(transcript + diarization where supported + AI summary), scoped to the signed-in user and
metered like a cloud session.

The insight that made this small: **`PostSessionRetranscriber.run(...)` already
transcribes an arbitrary `audioURL` into a session** (builds lines via
`PostSessionSegmentBuilder`, meters cloud usage by media duration, regenerates the
summary). Its engine/`run` layer is decoupled from `session.audioFileName`, and its
`replaceTranscript` step no-ops on an empty session before inserting lines. So import is:
**normalize the source → canonical `.m4a` → create an empty session → run the existing
pipeline over it.** The only genuinely new code is the media normalization + a thin
coordinator + the UI entry points.

## Decisions

1. **Normalize everything to the canonical `.m4a` first.** `MediaAudioExtractor`
   transcodes any imported audio/video to the app's own **AAC-LC, 16 kHz, mono, 32 kbps**
   `.m4a` (the exact format `SessionAudioRecorder` writes), placed in
   `SessionAudio/<uuid>.m4a`. This (a) lets both engines read one uniform input,
   (b) fixes `SonioxAsyncPostSessionEngine`'s hardcoded `Content-Type: audio/m4a`
   (a raw `.mp4`/`.mov` would be mislabeled), and (c) makes imported sessions play
   back and re-transcribe exactly like recorded ones. The shared AAC settings live on
   `SessionAudioRecorder.aacSettings` so live and imported audio can't drift.

2. **Video → audio-only, locally.** `MediaAudioExtractor` reads only the source's audio
   track via `AVAssetReader`; the video is discarded and never leaves the device. Files
   with no audio track fail with a clear "no audio to transcribe" error.

3. **Engine follows global Offline Mode — no per-import picker.** `RetranscriptionEngineKind.forCurrentMode`:
   Offline → **Parakeet** (on-device, free, single-stream); Online → **Soniox async**
   (cloud, metered, diarized). Matches the re-transcription decision so import behaves like the
   pipeline the user already chose. Parakeet requires the on-device model downloaded
   (same gate as re-transcription); otherwise a clear error.

4. **Billing = media duration**, `ceil(minutes)`, charged inside `PostSessionRetranscriber.run`
   (the same standalone `chargeMinutes` a cloud re-transcription uses). An up-front
   `canAfford(minutes:)` gate blocks an unaffordable cloud import and shows the existing
   `MacPaywallView` (via `LiveSessionStore.pendingPaywall`) **before** any session is
   created. Offline imports are free/ungated (guests are forced offline → always free).

5. **Audio retention follows the "Save session audio" setting** (`sessionPlayback` flag
   AND `LiveSessionStore.sessionAudioKey` — the same gate as live recording). Audio is
   always transcoded for transcription; after a successful run, if audio-saving is off,
   the `.m4a` is deleted and `audioFileName` nulled (transcript + summary preserved).

6. **Two entry points, gated by a dark-rollout flag.** A **toolbar "Import" button** next
   to Record and a **File ▸ "Import Audio or Video…" (⌘I)** command, both behind the new
   `Mac_file_import` remote flag (`FeatureFlag.fileImport`, default **OFF**). Drag-and-drop
   was considered but deferred (net-new to the codebase). The picker is SwiftUI
   `.fileImporter` (`[.audio, .movie]`); its security-scoped URL access is bracketed.

7. **Session created up front; progress shown in the session, not the list.** The empty
   session is created **before** the transcode, so it appears in the list immediately with
   the same **spinner** re-transcription uses (`TranscriptionsScreen.sessionRow` observes
   both managers) and its **detail view** shows the progress banner for the whole run — the
   list itself shows no banner. Because an import and a re-transcription would both drive
   `PostSessionRetranscriber.run` over one session, **re-transcribe is disabled while an
   import fills in that session** (detail menu gate + a defensive guard in
   `RetranscriptionManager.launch`), and the two banners are unified into one
   `PostSessionProgressBanner` rendered from a single top overlay (`postSessionBanner`).

8. **On failure/cancel the session is kept, never deleted.** Deleting a session the user
   may have open in detail would leave a dangling model; instead the session stays — one
   that reached the audio stage can simply be re-transcribed to retry, and errors surface
   via the list's alert. (A rare empty session from an early failure/cancel can be deleted
   manually; a launch sweep is a possible follow-up.)

## Flow / key files

- **`MediaAudioExtractor`** (`Services/Import/`) — `extractToSessionAudio(source:progress:)
  async throws -> (fileName, durationSeconds)`. `AVAssetReader` (audio track → 16 kHz mono
  PCM) → `AVAssetWriter` (AAC, `SessionAudioRecorder.aacSettings` + a mono `AVChannelLayoutKey`
  the encoder requires). A cooperative pull loop (not `requestMediaDataWhenReady`, whose
  `@Sendable` block fights the non-Sendable reader/writer under strict concurrency) runs off
  the main actor, honors `Task.checkCancellation()`, reports ~1%-throttled progress, and
  deletes the partial file on throw/cancel.
- **`FileImportManager`** (`ViewModel/`) — app-lifetime `@Observable @MainActor` singleton
  (mirrors `RetranscriptionManager`) so an import survives leaving/closing the window. Per
  run: refuse during a live recording → validate audio + duration → gate billing (paywall)
  → **create + save the empty session** (`userId = MacAuthManager.shared.ownerId`, title =
  filename stem) → transcode → set `audioFileName` → `PostSessionRetranscriber.run(...)` →
  retention cleanup. Keeps the session on failure/cancel. Exposes `jobs` + `isRunning(_:)`
  (list-row spinner) and `job(for:)` (detail banner).
- **`PostSessionProgressBanner`** (`Views/SessionDetail/`) — one banner component shared by
  import and re-transcription, driven by a `Kind`; replaces the old
  `RetranscriptionProgressBanner`. Rendered by `MacSessionDetailView`'s single top overlay
  (`postSessionBanner`, in the `+Retranscription` extension), which shows whichever pass is
  in flight for that session. The list shows only a per-row spinner — no banner.
- **Wiring:** `TranscriptionsScreen` (toolbar button, `.fileImporter`, error alert,
  `focusedSceneValue(\.importMedia)`, list-row spinner OR — no list banner); `MacFocusedValues`
  (`importMedia` key); `OpenCaptionsCommands` (File-menu command); `MacSessionDetailView`
  (`postSessionBanner` overlay; re-transcribe menu disabled while importing);
  `RetranscriptionManager.launch` (defensive import guard); `FeatureFlag` (`fileImport`);
  `SessionAudioRecorder` (shared `aacSettings`).

## Trade-offs / follow-ups

- **Drag-and-drop deferred.**
- The normalized `.m4a` is lossy 32 kbps 16 kHz mono — the accuracy ceiling is the
  compressed audio (same as live recordings).
- The session is created just before `run`, so a crash in that tiny window could leave an
  empty session (rare; acceptable — could add an empty-session launch sweep later).
- **No hard file-size/duration cap:** the transcoder streams at constant memory, Parakeet
  auto-chunks, and Soniox async handles long files. Revisit if abuse appears.
- **Localization:** macOS UI strings remain hardcoded English (no `LanguageManager`).
