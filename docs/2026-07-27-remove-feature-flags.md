# macOS: remove the remote feature-flag system (everything ships always-on)

**Date:** 2026-07-27 · **Scope:** Open Captions only
**Related:** `docs/2026-07-06-macos-firestore-share.md` (where the flag reader was
introduced), `docs/2026-07-08-macos-aec-feature-flag.md` (now superseded),
`docs/2026-07-08-macos-session-audio-playback.md`,
`docs/2026-07-16-macos-post-session-retranscription.md`,
`docs/2026-07-16-macos-file-import.md`

## Context

`FeatureFlagService` was built when Open Captions was one client of a
**team-operated** backend: a Firestore `config/featureFlags` doc that an operator
could edit to dark-launch a feature, or kill one in the field without shipping a
build. Five `Mac_`-prefixed keys ended up living there.

That premise is gone. The app has since been extracted into a standalone,
open-source project with its own per-deployment Firebase project (commit
`e2eb281`), lost its metering backend along with RevenueCat (#4, commit
`73cf54d`), and moved summaries to a direct client→Gemini call (#3, commit
`d124e23`). There is no longer any operator, any shared config doc, or any
release process on the other end of the flag: **a flag that shipped off could
never be turned on again**, and a flag that shipped on could only be turned off
by whoever happens to own the Firebase project a given fork is pointed at.

So the flags were no longer a control surface — they were a dependency on
infrastructure the project does not have, an extra Firestore listener at launch,
and (for two features) a permanent hiding place for finished code.

## Decisions

1. **All five flags resolve to permanently enabled.** Every
   `FeatureFlagService.shared.isEnabled(_:)` call became the constant `true` and
   the now-tautological condition was deleted outright (bodies unwrapped,
   compound conditions collapsed to their surviving non-flag terms) rather than
   left as `if true`.

   | Flag | Firestore key | Old default | Now |
   |---|---|---|---|
   | `.sessionSharing` | `Mac_session_sharing` | `true` | always on |
   | `.sessionPlayback` | `Mac_session_playback` | `true` | always on |
   | `.postSessionRetranscription` | `Mac_post_session_retranscription` | **`false`** | always on |
   | `.aecEnabled` | `Mac_aec_enabled` | `true` | always on |
   | `.fileImport` | `Mac_file_import` | **`false`** | always on |

2. **The two dark-rollout features become user-visible.** `Mac_file_import` and
   `Mac_post_session_retranscription` shipped `false` and — with no config doc to
   flip — had never been on for anyone. Enabling them is the only choice that
   makes the shipped code reachable: keeping them meant deleting working
   features. Concretely, the toolbar **Import** button and **File ▸ Import Audio
   or Video… (⌘I)** are now always present, as are the ⋯-menu **Re-transcribe**
   item and the Settings **Re-transcription** section.

3. **Local Settings toggles are untouched.** The per-device UserDefaults
   preferences that were *ANDed* with a flag survive unchanged and remain the
   real user-facing switch:
   - `LiveSessionStore.sessionAudioKey` — "Save session audio for playback"
     (default **on**) still gates session-audio recording and the imported-file
     audio-retention step.
   - `LiveSessionStore.retranscriptionAutoKey` — "Automatically re-transcribe
     after recording" (default **off**) still gates the automatic pass; the
     manual ⋯-menu trigger has no toggle and is simply always available.

   These are user preferences, not remote configuration. File import has no such
   toggle, so it is unconditionally available.

   One consequence of surfacing the Settings **Re-transcription** section for the
   first time: its auto toggle depends on the *adjacent* "Save session audio"
   toggle, because with no `.m4a` there is nothing to re-process — and
   `startAutomatic` runs `interactive: false`, so the failure is completely silent
   (no alert, no banner). It is therefore `.disabled(!saveSessionAudio)`, matching
   how the manual ⋯-menu item already hides itself when `audioFileName == nil`.

4. **The three self-re-arming kill switches are deleted, with nothing in their
   place.** `FirestoreSyncService.observeSessionSharingFlag`,
   `MacTranscriptionViewModel.observeAudioFlag`, and
   `MixedAudioCaptureService.observeAECFlag` each armed a one-shot
   `withObservationTracking` on `FeatureFlagService.shared` and re-armed itself
   on every fire, purely so a mid-session flip-off could tear the feature down
   gracefully (seal the live Firestore doc to `ended`; delete the partial `.m4a`;
   release the running canceller). **A feature that cannot be turned off remotely
   needs no graceful mid-session teardown**, so the observers, their arming call
   sites, and the helpers only they reached (`FirestoreSyncService.forceUpdate`,
   the guard-bypassing writer; `MixedAudioCaptureService.setAECEnabled` and its
   `aecEnabled` snapshot) went with them.

   The associated `[weak self]`-on-the-**outer**-`onChange` leak rule went away
   with its cause (the immortal `FeatureFlagService.shared` registrar). It is
   *not* a general retraction: `LiveSessionStore.armStatusMirroring` still uses
   the same self-re-arming pattern against the view model and still needs its
   weak capture.

5. **AEC-specific: the lock stays, the flag snapshot goes.**
   `MixedAudioCaptureService.aecLock` was justified by *three* threads touching
   AEC state (main actor, the detached `configureMicEngine` task, the mic render
   thread). Removing the main-actor flag writer leaves two, and the render thread
   still races construction and teardown of `aec`, so the `NSLock` and the
   snapshot-into-a-strong-local discipline in `handleMicBuffer` are kept verbatim.
   Only the `aecEnabled` gate and the build-vs-flip re-check are gone.

## What changed, file by file

**Deleted**

- `OpenCaptions/Model/FeatureFlag.swift` — the whole `enum FeatureFlag`.
- `OpenCaptions/Services/FeatureFlagService.swift` — the `@Observable @MainActor`
  singleton: Firestore listener, UserDefaults cache, `isEnabled(_:)`.
- `OpenCaptions/Services/Audio/MixedAudioCaptureService+AEC.swift` — existed only
  to hold `setAECEnabled` + `observeAECFlag`.

**Edited**

- `OpenCaptionsApp.swift` — dropped the launch-time `FeatureFlagService.shared.startListening()`.
- `Services/Sync/FirestoreSyncService.swift` (+`+Writes`, `+SessionSync`) — dropped the
  `sessionSharing` guard from `createDoc`/`updateDoc` and the session/line writers, plus
  `observeSessionSharingFlag` and `forceUpdate`. (`+UserPrefs` is a doc-comment fix only:
  it explained *why* it avoids `createDoc`/`updateDoc` in terms of the flag guard; the real
  reasons — session-document scoping and create-once audit stamping — still hold.)
- `Services/Audio/MixedAudioCaptureService.swift` (+`+Mic`) — removed the `aecEnabled`
  snapshot; `configureMicEngine` builds the canceller unconditionally (the `aec == nil`
  init-failure fallback to a plain sum is unchanged).
- `ViewModel/MacTranscriptionViewModel+AudioRecording.swift` — removed `observeAudioFlag`
  and its teardown path; `+AudioSource.swift` — removed the `observeAECFlag()` arming call
  from `makeAudioSource`.
- `ViewModel/RetranscriptionManager.swift`, `ViewModel/FileImportManager.swift` — flag
  terms dropped from the launch guard and the audio-retention check.
- `Views/Shell/TranscriptionsScreen.swift` — the `showImport` computed gate is gone; the
  Import button is unconditional.
- `Views/SessionDetail/MacSessionDetailView.swift` (+`+Playback`, `+Retranscription`),
  `Views/LiveTranscription/MacLiveTranscriptionView+Sharing.swift`,
  `Views/Settings/MacSettingsView.swift` — share / player-bar / re-transcribe affordances
  no longer flag-gated. Non-flag conditions (`!isOffline`, `playback.isAvailable`,
  auth state, in-flight-job checks) are all preserved. `MacSettingsView` also gained
  `.disabled(!saveSessionAudio)` on the auto-re-transcribe toggle (see decision 3).
- **Doc-comment-only fixes**, in files with no code change, where prose still described
  flag gating: `LiveSessionStore.swift` (the `retranscriptionAutoKey` doc),
  `MacTranscriptionViewModel.swift` (3 sites), `OpenCaptionsCommands.swift`,
  `Utility/HotKeys/MacFocusedValues.swift`, `MacSessionDetailView+SpeakerEditing.swift`.
- `CLAUDE.md` — records that there is no remote configuration; every feature is
  compiled in and always enabled.
- The five dated notes listed under **Related** above, plus
  `docs/2026-07-10-macos-offline-mode.md`, carry inline "removed 2026-07-27" markers
  rather than being rewritten; `docs/2026-07-08-macos-aec-feature-flag.md` is marked
  **SUPERSEDED** in full.

## Consequences

- **One fewer Firestore listener and one fewer launch dependency.** Flag
  resolution no longer sits in front of launch-time UI gates, so there is no
  cold-start window where a gated affordance pops in after the first snapshot.
- **Leftovers are inert, not cleaned up.** Any deployment's Firestore
  `config/featureFlags` doc is simply never read again — it can be deleted at the
  operator's convenience, and nothing breaks if it isn't. The stale
  `mac_featureFlagsCache` UserDefaults key likewise stays behind on machines that
  ran an older build and is now dead weight; no migration removes it, because
  nothing reads it and a stray key costs nothing.
- **Turning a feature off now requires a build.** Accepted: this is a
  single-developer, source-available app where the person who would flip a flag
  is the person who would ship the build.
- **Re-introducing remote config later is a fresh design**, not a revival — it
  would need a config source that a fork actually owns (Remote Config, a bundled
  plist, or a local debug menu), not a hardcoded shared Firestore path.

## Verification

Build the **OpenCaptions** scheme in Xcode, then confirm each formerly-gated
surface is present and functional:

- **Sharing** — live-toolbar Share button and the saved-session "Share…" menu item
  appear; a live session mirrors to Firestore; the detail-view item still hides in
  Offline Mode (that gate is `!isOffline`, not a flag).
- **Session playback** — with "Save session audio for playback" **on**, a finished
  session shows the player bar and tap-to-seek; turning the Settings toggle **off**
  still suppresses recording (the local preference must keep working).
- **Post-session re-transcription** — the ⋯-menu "Re-transcribe" item and the
  Settings "Re-transcription" section are visible; the auto toggle still defaults off.
- **File import** — the toolbar "Import" button and File ▸ "Import Audio or Video…"
  (⌘I) are visible and run a full import.
- **AEC** — "Microphone + System Audio" over built-in speakers logs
  *"OpenCaptionsAEC ready … engaged"* (Console.app, subsystem
  `com.muhammadramdan.OpenCaptions`, category `MixedAudio`); remote participants are
  transcribed once, not twice.
- Grep for `FeatureFlag`, `isEnabled(`, `withObservationTracking` under
  `OpenCaptions/` — only `LiveSessionStore.armStatusMirroring` should match the last one.
- Symbol greps are not enough: stale *prose* outlives the code it described, and it
  lives in files the refactor never opened. Also run a case-insensitive
  `grep -rin "feature flag\|remote flag\|kill switch\|flag is on\|Mac_" OpenCaptions/`
  — every surviving hit should be a deliberate historical mention, not a live claim.
