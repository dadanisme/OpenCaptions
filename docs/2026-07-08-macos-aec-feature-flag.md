# macOS: gate the mixed-source software AEC behind a remote feature flag

**Date:** 2026-07-08
**Issue:** #231 (follow-up to #208 — the software echo canceller from `docs/2026-07-06-macos-mic-system-audio-fix.md`)
**Scope:** OgmoMac only

## Problem

The "Microphone + System Audio" mixed source runs software acoustic echo
cancellation (`OgmoAEC`, SpeexDSP-backed) to strip the system audio's
speaker-bleed out of the mic before summing the two streams. It was engaged
unconditionally in `MixedAudioCaptureService+Mic.swift`. If the canceller
regresses in the field (over-cancels, distorts, or CPU-regresses on some
hardware), there was no way to fall back to the uncancelled plain-sum mix
without shipping a new build.

## Decision

Wrap AEC engagement in a new remote feature flag, `FeatureFlag.aecEnabled`
(Firestore key **`Mac_aec_enabled`**, `defaultValue = true`). When off, the mix
stays an uncancelled plain sum — the pre-existing `aec == nil` fallback path.
The default is `true`, so with no remote config the behavior is unchanged.

- **Flag off at session start** → `configureMicEngine` skips `OgmoAEC` init; `aec`
  stays nil; `handleMicBuffer` sums mic + system with no cancellation.
- **Flag flipped off mid-session** → the running canceller is released and the mix
  falls back to plain sum for the rest of the session.
- **Flag flipped back on** → does **not** auto-resume cancellation; a fresh AEC is
  built only at the next session start. This matches the no-auto-resume
  convention of the other Mac kill switches (`Mac_session_sharing`,
  `Mac_session_playback`).

## Why the flag lives partly in the service and partly in the view model

The **build gate** stays in `configureMicEngine` (`+Mic`) per the issue — that is
where the OgmoAEC was already constructed. The **flag observer** and the
thread-safe setter live in a new `MixedAudioCaptureService+AEC.swift`, mirroring
`FirestoreSyncService.observeSessionSharingFlag` (a service that owns its own flag
observer). The view model arms the observer from `makeAudioSource` — the single
choke point through which both the start and live-switch paths build a source —
via a `(source as? MixedAudioCaptureService)?.observeAECFlag()` call, because only
the mixed source has an AEC.

## Threading — the crux

`FeatureFlagService.isEnabled` is `@MainActor`, but `aec` is created in
`configureMicEngine` (runs off-main in a detached `.userInitiated` task) and its
`process`/`processReverse` are driven on the mic **render thread**. Three threads
now touch AEC state, so:

- A resolved-flag snapshot (`aecEnabled`) plus the `aec` reference are guarded by a
  single `NSLock` (`aecLock`). `NSLock` is the codebase's established cross-thread
  primitive (`AudioRingBuffer`, `SessionAudioRecorder`), and the render thread
  already takes one each callback via `AudioRingBuffer.read`, so one more short,
  near-always-uncontended lock is consistent and cheap.
- **`observeAECFlag`** (main actor) runs its initial `setAECEnabled(flagValue)`
  synchronously *inside* `makeAudioSource`, which fully returns before `sendData`
  spawns the detached task — so `configureMicEngine`'s gate read sees the correct
  value (happens-before via the lock).
- **Mid-session release is race-free:** `handleMicBuffer` snapshots `aec` into a
  strong local under the lock, then calls `process`/`processReverse` on that local.
  A concurrent `setAECEnabled(false)` (main actor) nils the instance's reference,
  but the object outlives the local, so it is never deallocated mid-`process`.
  OgmoAEC's "single thread drives process/processReverse" rule still holds — only
  the render thread ever calls them; the main actor only releases the reference.
- **Build-vs-flip race:** if the flag flips off while `configureMicEngine` is
  constructing the OgmoAEC, the post-build assignment is re-checked under the lock
  (`if aecEnabled { aec = canceller }`) and the just-built canceller is dropped
  before any tap is installed.

## Kill-switch leak guard

`observeAECFlag` puts `[weak self]` on the **outer** `withObservationTracking`
`onChange` closure (not just a nested `Task`), because the handler is registered
with the immortal `FeatureFlagService.shared` registrar; a strong capture would
pin the per-session `MixedAudioCaptureService` alive until the flag next changed.
Same rule (and the same reason) as `MacTranscriptionViewModel.observeAudioFlag`.
It re-arms only while enabled — once disabled, the AEC is released and there is
nothing left to watch.

## Files touched

- `OgmoMac/Model/FeatureFlag.swift` — new `case aecEnabled = "Mac_aec_enabled"`.
- `OgmoMac/Services/Audio/MixedAudioCaptureService.swift` — `aecEnabled` snapshot +
  `aecLock`; doc updates on `aec`.
- `OgmoMac/Services/Audio/MixedAudioCaptureService+Mic.swift` — flag-gated build,
  locked render-thread snapshot, locked teardown release.
- `OgmoMac/Services/Audio/MixedAudioCaptureService+AEC.swift` — new: `setAECEnabled` +
  `observeAECFlag`.
- `OgmoMac/ViewModel/MacTranscriptionViewModel+AudioSource.swift` — arm the
  observer in `makeAudioSource`.

## Verification

- Build the `OgmoMac` scheme in Xcode.
- On a physical Mac, "Microphone + System Audio" over the built-in speakers:
  - **Flag on** (or absent): Console.app (subsystem `com.muhammadramdan.OgmoMac`,
    category `MixedAudio`) logs *"OgmoAEC ready … engaged"*; other participants are
    transcribed once.
  - **Flag `Mac_aec_enabled = false`** in `config/featureFlags` before start: logs
    *"OgmoAEC disabled by feature flag — mix uncancelled (plain sum)"*; the mix is a
    plain sum (speaker-bleed doubles the remote audio on built-in speakers).
  - **Flip the flag off mid-session:** cancellation stops within the listener's
    round-trip; the session continues as a plain sum.
