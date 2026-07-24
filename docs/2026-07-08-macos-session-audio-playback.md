# macOS Session Audio Persistence + Synced Transcript Playback

**Date:** 2026-07-08 · **Scope:** Open Captions (native macOS) only

Persists each Open Captions transcription session's audio to disk and adds a playback UI on the saved-session detail screen (`MacSessionDetailView`): a player bar (play/pause, scrubber, elapsed/total) plus a transcript that highlights the line under the playhead, auto-scrolls to it, and lets you tap any bubble to seek there. Every `TranscriptionLine` already stored `startMs`/`endMs`, so only the audio itself and the UI were missing.

## Audio format — AAC-LC `.m4a`, 16 kHz mono, ~32 kbps

The capture pipeline already delivers 16 kHz mono Float32 (the exact stream sent to Soniox), so the recording can't exceed that fidelity regardless. Options considered:

| Format | Size / hour | Verdict |
|---|---|---|
| Raw Float32 `.caf` | ~230 MB | Rejected — a 30 hr/mo student ≈ 7 GB. |
| **AAC-LC `.m4a`, 32 kbps** | **~14 MB** | **Chosen** — voice-appropriate; 30 hr/mo ≈ 0.4 GB. |

`SessionAudioRecorder` opens `AVAudioFile(forWriting:settings:commonFormat:.pcmFormatFloat32,interleaved:false)` with AAC settings; `write(from:)` transcodes the Float32 buffers. The `.m4a` edit list means `AVAudioPlayer.currentTime` is presented on a trimmed timeline from 0 (no persistent priming offset).

## Storage & cleanup

- Files live at `Application Support/SessionAudio/<uuid>.m4a` (inside the app sandbox → no extra entitlement). Only the **filename** is persisted, on the new optional `TranscriptionSession.audioFileName` (additive optional → SwiftData lightweight migration, no `SchemaMigrationPlan`). Absolute URLs are resolved at read time via `SessionAudioStore`, so a container-path change never invalidates a reference.
- The filename is a fresh UUID minted at record start (no session row exists yet) and stamped onto the session **only at final save** (`saveSession`), so any discarded/crashed leftover is unreferenced.
- Cleanup: the single swipe-to-delete site (`TranscriptionsScreen.deleteSessions`) removes the file (the SwiftData cascade only covers relationships, not external files); `SessionAudioOrphanSweep` removes unreferenced `.m4a`s at launch. The sweep unions the **live in-flight filename** into the "keep" set to avoid a launch-window TOCTOU where a just-started recording's open file is swept.

## Gating — remote flag + local toggle

Recording happens only when **both** are on:

- **Remote flag** `FeatureFlag.sessionPlayback` = `Mac_session_playback` (default **ON**). Gates the recorder, the player bar, and the transcript's playback affordances (highlight + tap-to-seek). A self-re-arming `withObservationTracking` kill switch tears down an in-progress recording (deleting the partial file) if the flag flips off mid-session.
- **Local Settings toggle** "Save session audio for playback" (`LiveSessionStore.sessionAudioKey`, default **ON**, registered in `OpenCaptionsApp.init`, read at record time).

> **Observation gotcha:** the self-re-arming kill-switch pattern (copied from `FirestoreSyncService.observeSessionSharingFlag`) is safe on singletons but leaks a per-session object if the `onChange` closure captures `self` strongly — `FeatureFlagService.shared`'s registrar is immortal. `[weak self]` MUST be on the **outer** `onChange` closure (a nested `Task { [weak self] }` does not prevent the outer strong capture).

## Recording strategy — faithful, no padding

Frames are written **back-to-back with no padding**. The recording is therefore byte-for-byte the audio stream sent to Soniox, so **the recording's playback position equals Soniox's audio-stream position**. Pauses need no handling: while paused, both the recorder and Soniox simply receive nothing, so they resume in lockstep.

Two earlier approaches were tried and discarded:
1. **Per-frame wall-clock silence padding** (pad the file to `totalActiveTime` on every frame). This made **system-audio** playback choppy: the mic tap is real-time-paced, but the system-audio Core Audio process tap runs on the *output device's* clock, which doesn't track `CFAbsoluteTime` frame-for-frame — so the recorder peppered the file with catch-up micro-silences. (Soniox was unaffected because its path streams the raw frames.)
2. **Segment-boundary alignment** (pad once per streaming segment to the session clock). Correct, but made unnecessary by matching Soniox timestamps (below), so it was removed for simplicity.

## Sync — match Soniox's token timestamps, not the wall clock

**Root cause of the initial ~5 s desync:** `accumulateText` received each token's Soniox `start_ms`/`end_ms` but ignored them, stamping `totalActiveTime` (wall clock at final-arrival) instead. Soniox holds a final back until its accumulator/finalization window settles, so a final arrives **seconds after** the audio it describes — wall-clock-at-arrival lags the audio by that delay (this is finalization/accumulator delay, not raw ASR compute latency).

**Fix:** stamp line `startMs`/`endMs` from the token's own Soniox timestamps (`OnlineTranscriberService+Messages` already parses them). Because the recording is the exact stream Soniox received, `token.start_ms` maps **directly** to a file offset — seeking to a line needs no correction, highlighting is exact, and pauses stay aligned for free. This also drops the recording padding entirely (see above). Display timestamps and the cached session duration are now audio-stream-relative, which matches the scrubber.

## Playback UI

- `PlaybackViewModel` (`@MainActor @Observable`) wraps `AVAudioPlayer` with a ~10 Hz Task-based ticker (no delegate → no `NSObject`). Visibility is backed by an **observed** `isLoaded` (not the `@ObservationIgnored` player), so the bar reactively appears after the async `load()`.
- Player bar is docked via `.safeAreaInset(edge:.bottom)`, gated on the flag + `isAvailable`, styled to match `MacTranscriptionControls`.
- Transcript: `ScrollViewReader` + `.id(persistentModelID)`; active line = `lines.last { $0.startMs <= currentMs }`; auto-scroll to it while playing; **tap anywhere on a bubble** to seek + play.
- **Trade-off:** `.textSelection(.enabled)` was removed from the transcript rows — on macOS, selectable text swallows the single click, making whole-bubble tap-to-seek unreliable. Tap-to-seek was prioritized; the summary tab keeps selection. (Revisit with `.simultaneousGesture` if inline copy is wanted back.)

## Teardown matrix

| Path | On-disk file |
|---|---|
| `stop()` with content | keep + stamp `audioFileName` at save |
| `stop()` no content | delete |
| `discard()` | delete |
| `failSession()` | keep (a later Stop & Save stamps it); a later empty stop/discard deletes it by name |
| connect failure in `start()` | delete (never streamed a frame) |
| crash mid-session | orphan-swept at next launch |

`SessionAudioRecorder.close(deletingFile:)` is one-shot/idempotent and auto-deletes an empty (0-sample) file regardless.

## Known issue

Mixed **Microphone + System Audio** mode records glitched system audio on playback (mic-only and system-only are clean) — tracked separately. The artifact is in the mixed capture path (`MixedAudioCaptureService`), not the recorder.
