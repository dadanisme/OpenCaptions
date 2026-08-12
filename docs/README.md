# docs/ — Open Captions knowledge base

One dated design/decision note per row (`{YYYY-MM-DD}-{topic}.md`), oldest first. This index
is the source of truth for what's current vs. historical — check here before trusting a note's
claims about live behavior, instead of guessing from a filename or reading CLAUDE.md's aside.

- **Current** — still describes the app as it stands (in each note's own scope; some
  implementation details elsewhere may have shifted without a full rewrite — see the cross-links
  inside `2026-08-10-remove-accounts-and-firestore.md` and `2026-07-27-remove-feature-flags.md`
  for the specific stale mentions those two removals left behind in otherwise-current notes).
- **Historical** — the subsystem the note is about was later removed or fully replaced. Kept
  for design-history context only; each one carries a banner at the top of the file itself
  pointing to what superseded it, so opening the note directly (not via this index) still gives
  the signal.

When adding a new note, add a row here too.

| Date | Note | Description | Status |
|---|---|---|---|
| 2026-07-04 | [macos-standalone-mvp](2026-07-04-macos-standalone-mvp.md) | Decision to build OpenCaptions as a fully standalone, dependency-free macOS target instead of sharing an iOS/macOS codebase. | Current |
| 2026-07-05 | [macos-auth-and-scoping](2026-07-05-macos-auth-and-scoping.md) | Adds Firebase-backed Sign in with Apple plus email/password auth and per-user SwiftData query scoping. | **Historical** → [2026-08-10-remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md) |
| 2026-07-05 | [macos-google-signin](2026-07-05-macos-google-signin.md) | Adds Google Sign-In as the primary auth path and hides the Apple button after an aud-claim rejection. | **Historical** → [2026-08-10-remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md) |
| 2026-07-05 | [macos-mic-system-mix-vpio](2026-07-05-macos-mic-system-mix-vpio.md) | Adds a combined mic+system-audio source using AVAudioEngine's VPIO to cancel speaker bleed. | Current |
| 2026-07-05 | [macos-system-audio-capture](2026-07-05-macos-system-audio-capture.md) | Adds selectable whole-system-audio capture via ScreenCaptureKit as an alternative to the microphone source. | Current |
| 2026-07-06 | [macos-captions-overlay-and-background-session](2026-07-06-macos-captions-overlay-and-background-session.md) | Adds an always-on-top NSPanel captions overlay and hoists the live session into `LiveSessionStore`. | Current |
| 2026-07-06 | [macos-firestore-share](2026-07-06-macos-firestore-share.md) | Adds live Firestore session mirroring, public share links, and optional password protection. | **Historical** → [2026-08-10-remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md) |
| 2026-07-06 | [macos-mic-system-audio-fix](2026-07-06-macos-mic-system-audio-fix.md) | Removes VPIO, adds Core Audio process taps for system audio, cancels echo via vendored SpeexDSP. | Current |
| 2026-07-07 | [macos-source-app-attribution](2026-07-07-macos-source-app-attribution.md) | Shows a per-line app icon attributing system audio to its source app via time-correlated matching. | Current |
| 2026-07-08 | [macos-aec-feature-flag](2026-07-08-macos-aec-feature-flag.md) | Gated the mixed-source software echo canceller behind a remote Firestore feature flag. | **Historical** → [2026-07-27-remove-feature-flags](2026-07-27-remove-feature-flags.md) |
| 2026-07-08 | [macos-session-audio-playback](2026-07-08-macos-session-audio-playback.md) | Records session audio as AAC `.m4a` and adds a synced playback UI matching Soniox token timestamps. | Current |
| 2026-07-09 | [macos-app-nap-keepalive](2026-07-09-macos-app-nap-keepalive.md) | Holds an `NSProcessInfo` activity assertion for the whole live session to survive App Nap throttling. | Current |
| 2026-07-09 | [macos-captions-overlay-autoscroll](2026-07-09-macos-captions-overlay-autoscroll.md) | Fixes captions overlay/live view auto-scroll by scrolling to real row ids and re-pinning after a flush. | Current |
| 2026-07-10 | [macos-app-wide-font-size](2026-07-10-macos-app-wide-font-size.md) | Adds a second, independent app-wide UI text-size slider (80–300%), separate from transcript size. | Current |
| 2026-07-10 | [macos-consumable-billing](2026-07-10-macos-consumable-billing.md) | Adds RevenueCat consumable-minute billing that gates and meters cloud Soniox sessions. | **Historical** → removed wholesale, commit `73cf54d` (see CLAUDE.md's Metering section) |
| 2026-07-10 | [macos-distribution](2026-07-10-macos-distribution.md) | Decides on Mac App Store distribution, the signing team, and three consumable minute-pack IAP products. | Current |
| 2026-07-10 | [macos-global-hotkeys](2026-07-10-macos-global-hotkeys.md) | Adds system-wide Carbon `RegisterEventHotKey` shortcuts for start/stop, pause/resume, and captions toggle. | Current |
| 2026-07-10 | [macos-offline-mode](2026-07-10-macos-offline-mode.md) | Collapses the 3-way engine picker into one binary Offline Mode toggle running on-device Nemotron. | **Historical** → [2026-08-12-macos-transcription-engine-selector](2026-08-12-macos-transcription-engine-selector.md) |
| 2026-07-10 | [macos-on-device-engines](2026-07-10-macos-on-device-engines.md) | Adds selectable on-device Parakeet TDT v2 and Nemotron 560ms engines via FluidAudio. | Current |
| 2026-07-10 | [macos-question-highlight](2026-07-10-macos-question-highlight.md) | Highlights question-ending sentences in transcripts via sentence scanning and a selection-color tint. | Current |
| 2026-07-11 | [macos-onboarding](2026-07-11-macos-onboarding.md) | Adds a first-run wizard with a sign-in-vs-offline mode choice and an account-free offline guest mode. | **Historical** → [2026-08-10-remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md) |
| 2026-07-12 | [macos-consolidated-action-items](2026-07-12-macos-consolidated-action-items.md) | Adds a sidebar section aggregating AI-generated action items across all sessions. | Current |
| 2026-07-14 | [macos-account-deletion](2026-07-14-macos-account-deletion.md) | Adds an in-app Delete Account flow with per-provider reauth and a local SwiftData/audio wipe. | **Historical** → [2026-08-10-remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md) |
| 2026-07-15 | [macos-email-capture-and-support](2026-07-15-macos-email-capture-and-support.md) | Adds a Firestore marketing-opt-in toggle and a Settings Support tab with prefilled `mailto` actions. | **Historical** → [2026-08-10-remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md), [2026-08-10-macos-settings-navsection](2026-08-10-macos-settings-navsection.md) |
| 2026-07-15 | [macos-name-mention-highlight-notify](2026-07-15-macos-name-mention-highlight-notify.md) | Highlights the user's spoken name as bold `@Name`, sends focus-gated alerts, biases Soniox recognition. | Current |
| 2026-07-16 | [macos-file-import](2026-07-16-macos-file-import.md) | Adds toolbar/File-menu import of audio or video files into the re-transcription pipeline. | Current |
| 2026-07-16 | [macos-mic-system-sync-fix](2026-07-16-macos-mic-system-sync-fix.md) | Fixes mic-leads-system audio gap and dead AEC by trimming the system ring buffer's latency cushion. | Current |
| 2026-07-16 | [macos-onboarding-clip-fix](2026-07-16-macos-onboarding-clip-fix.md) | Fixes onboarding step dots/button clipping via `windowResizability(.contentMinSize)`. | Current |
| 2026-07-16 | [macos-post-session-retranscription](2026-07-16-macos-post-session-retranscription.md) | Adds a pluggable batch re-transcription engine (Parakeet or Soniox async) to redo a finished session. | Current |
| 2026-07-16 | [macos-system-audio-pitch-fix](2026-07-16-macos-system-audio-pitch-fix.md) | Fixes pitched-up system audio by deriving the tap's sample rate from the aggregate device's nominal rate. | Current |
| 2026-07-16 | [macos-transcript-auto-scroll-gating](2026-07-16-macos-transcript-auto-scroll-gating.md) | Gates live transcript/captions auto-scroll behind scroll position so re-reading isn't yanked back down. | Current |
| 2026-07-24 | [macos-native-gemini-summary](2026-07-24-macos-native-gemini-summary.md) | Implements direct Gemini `generateContent` REST calls for backend-less AI summaries. | **Historical** → [2026-08-04-macos-openrouter-summaries](2026-08-04-macos-openrouter-summaries.md) |
| 2026-07-27 | [remove-feature-flags](2026-07-27-remove-feature-flags.md) | Deletes the Firestore-backed `FeatureFlagService`; all five flags become permanently enabled. | Current |
| 2026-07-28 | [macos-custom-vocabulary](2026-07-28-macos-custom-vocabulary.md) | Adds a Vocabulary sidebar editor for Soniox term biasing, cloud-only. | Current |
| 2026-07-28 | [macos-tahoe-app-icon](2026-07-28-macos-tahoe-app-icon.md) | Switches app-icon delivery from an asset-catalog set to a plain `.icns` file, fixing the Dock icon size. | Current |
| 2026-07-29 | [macos-live-line-building](2026-07-29-macos-live-line-building.md) | Removes the sentence-buffering token accumulator; each finalized token commits straight into the model. | Current |
| 2026-07-29 | [macos-speaker-auto-naming](2026-07-29-macos-speaker-auto-naming.md) | Summarization pass predicts speaker identities from self-intro/address evidence, with confidence thresholds. | Current |
| 2026-07-31 | [macos-markdown-export](2026-07-31-macos-markdown-export.md) | Every session is continuously mirrored to markdown/audio files in a user-chosen folder, no toggle. | Current |
| 2026-08-04 | [macos-openrouter-summaries](2026-08-04-macos-openrouter-summaries.md) | AI summaries moved from direct Gemini calls to OpenRouter, adding provider fallback and bounded retry. | Current |
| 2026-08-04 | [session-list-speaker-names](2026-08-04-session-list-speaker-names.md) | Session list rows show a cached, truncated "who was here" speaker-names summary. | Current |
| 2026-08-06 | [macos-workspaces](2026-08-06-macos-workspaces.md) | New `Workspace` model lets a session be filed under one named container with its own export folder. | Current |
| 2026-08-10 | [macos-runtime-api-keys](2026-08-10-macos-runtime-api-keys.md) | Soniox and OpenRouter API keys can now be entered at runtime, stored in Keychain. | Current |
| 2026-08-10 | [macos-settings-navsection](2026-08-10-macos-settings-navsection.md) | Moves Settings from a separate fixed-size window scene into a `NavSection` destination. | Current |
| 2026-08-10 | [macos-transcriptions-search](2026-08-10-macos-transcriptions-search.md) | Adds a `.searchable` field filtering sessions by title/description/summary plus a transcript-line scan. | Current |
| 2026-08-10 | [remove-accounts-and-firestore](2026-08-10-remove-accounts-and-firestore.md) | Removes the whole account/Firestore backend (#33); the app becomes fully local-only. | Current |
| 2026-08-12 | [coreai-parakeet-spike](2026-08-12-coreai-parakeet-spike.md) | Spike: evaluates Apple Core AI's Parakeet export against FluidAudio (#44); recommends deferring. | Current |
| 2026-08-12 | [macos-transcription-engine-selector](2026-08-12-macos-transcription-engine-selector.md) | Replaces the binary Offline Mode toggle with a three-way Soniox/Nemotron/Parakeet picker (#35). | Current |

## Two cross-links that don't resolve

Two notes reference design notes from the pre-extraction, multi-platform repo that were never
carried into this standalone one:

- `2026-07-16-macos-post-session-retranscription.md` → a `2026-06-24-transcription-engine-abstraction`
  note.
- `2026-08-04-session-list-speaker-names.md` → a `2026-06-02-home-screen-derived-fields` note.

Both are annotated in place (not linked as `docs/...md`, so they don't read as a resolvable
path) rather than backfilled — the targets don't exist anywhere in this repo's history, so
recreating them would be fabricating design rationale that was never written here.
