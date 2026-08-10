# macOS: remove accounts and Firestore sync — fully local-only (#33)

**Date:** 2026-08-10 · **Scope:** Open Captions only
**Related:** `docs/2026-07-05-macos-auth-and-scoping.md`, `docs/2026-07-05-macos-google-signin.md`,
`docs/2026-07-06-macos-firestore-share.md`, `docs/2026-07-14-macos-account-deletion.md`,
`docs/2026-07-15-macos-email-capture-and-support.md`, `docs/2026-07-11-macos-onboarding.md`
(all now historical — describe a removed subsystem), `docs/2026-07-27-remove-feature-flags.md`
(the precedent for this kind of removal note)

## Context

Issue #33 continues the simplification trajectory that already removed RevenueCat
billing (`73cf54d`) and the remote feature-flag system (2026-07-27): Firebase was
the last backend dependency left. Open Captions used it for two unrelated things —
**Auth** (Google/Apple/email sign-in, gating the app and scoping local data per
uid) and **Firestore** (mirroring live sessions to a read-only web client, plus
password-protected share links via two Cloud Functions callables). Both are now
gone. The app is fully local-only: no sign-in, no cloud database, no web sharing.
Cloud Soniox transcription (diarization, custom vocabulary, AI summaries) was
already gated by a single app-wide API key, not by account status, so it is now
available to **everyone** by default — the old guest-locked-to-Offline-Mode
restriction no longer exists because there's no "guest" concept left to lock.

## What was deleted

- **Auth**: `MacAuthManager` + its five extensions (`+Apple`, `+Email`, `+Google`,
  `+Onboarding`, `+AccountDeletion`), the Google Sign-In SPM package, the Apple
  Sign-In entitlement, `MacSignInControls`, `MacOnboardingSignInStep`, the Settings
  Account tab (`MacAccountSettingsView`, `MacDeleteAccountSheet`), and the
  `keychain-access-groups` entitlement (it existed solely for FirebaseAuth's
  keychain persistence).
- **Firestore/sharing**: `FirestoreSyncService` + its four extensions, the
  FirebaseFirestore and FirebaseFunctions SPM products, `SessionLinkSharer`,
  `SessionPasswordService`, `MacShareSessionSheet`, the live-session mirroring in
  `MacTranscriptionViewModel+Firestore`, and `TranscriptionSession.cloudSessionId`
  / `.hasPassword`.
- **Uid scoping**: `TranscriptionSession.userId` and `Workspace.userId`, and
  `SessionOwnerBackfill` (the utility that reconciled legacy/guest-owned rows —
  with one local library there's nothing left to reconcile).
- **Firebase SDK entirely**: `FirebaseCore`/`FirebaseApp.configure()`, the
  `firebase-ios-sdk` SPM package, `GoogleService-Info.plist`, and
  `REVERSED_CLIENT_ID` (Config.xcconfig / OpenCaptions-Info.plist's
  `CFBundleURLTypes`). This also closes out the old
  `SESSION_SHARE_BASE_URL` known config gap — the file that read it
  (`MacShareSessionSheet`) is gone.

## What replaced it

- **The launch gate** (`OpenCaptionsApp`) is now just `hasCompletedOnboarding` —
  every launch goes straight to the local library.
- **Onboarding** keeps its Welcome → Mode → Capture → Permissions → Ready shape,
  but the Mode step is reframed as a pure Cloud-vs-Offline accuracy/privacy
  tradeoff (no "sign in", no cross-device sync claim), and the Download step
  (on-device model download) is visited only on the offline path — cloud needs no
  extra setup step at all.
- **A new local-only "Your Name" preference** (Settings → General, first section,
  `LiveSessionStore.yourNameKey`) replaces `MacAuthManager.shared.userName` as the
  source for three features that quietly depended on the signed-in display name:
  Soniox's live-transcription context payload, the vocabulary screen's
  "always-included" own-name term, and the `@Name` mention-highlight/notify
  feature. Without this replacement those three would have silently gone inert —
  the issue itself didn't call this out, so it's worth flagging for anyone
  auditing the change.
- **The SwiftData schema change is this app's first `VersionedSchema`/
  `SchemaMigrationPlan`.** Every prior schema change (adding `audioFileName`,
  `exportFolderName`, `userId` itself, etc.) was a bare property edit relying on
  implicit lightweight-migration inference. Dropping three fields simultaneously
  from data already on real users' disks is a different risk class, so
  `OpenCaptions/Model/Migration/` now has `OpenCaptionsSchemaV1` (a frozen mirror
  of the pre-#33 shape), `OpenCaptionsSchemaV2` (today's shape), and
  `OpenCaptionsMigrationPlan` (one `.lightweight` stage). Future schema changes
  should add a new `SchemaV3` + migration stage rather than editing V1/V2 in
  place.
- **Sidebar identity block** (`SidebarProfileFooter`) → **`SidebarSettingsFooter`**,
  a plain "Settings" row with no identity to show.
- **Settings** drops to three tabs: General, Shortcuts, Support.

## What has no replacement (deliberately)

- **Marketing consent** (the old Account tab's "Communications" section) is gone
  with nothing standing in for it. It only ever existed because Firebase Auth
  captured an email at sign-in; once there's no sign-in, there's no email to
  attach consent to, so the whole feature — not just its Firestore storage — goes
  away as a consequence of removing accounts, not as an independent product cut.
- **Offline Mode's cross-device Firestore sync** likewise disappears — there's no
  "device" identity left to sync across.
- **Account deletion** is moot; there's no account.

## Out-of-repo follow-ups

- The two `setSessionPassword`/`removeSessionPassword` Cloud Functions callables
  (region `asia-southeast1`) are deployed from a separate backend project not
  present in this repo. This client-side change removes the only caller but does
  not decommission them — that's a follow-up for whoever owns that project.
- Firestore documents for sessions already shared before this change
  (`users/{uid}/sessions/{id}`, `sessionIndex/{id}`) are not deleted by anything
  client-side and remain live/publicly readable in production Firestore
  indefinitely unless cleaned up separately.

## Docs left as historical (not edited)

Per this project's convention (see CLAUDE.md's Documentation section, and the
2026-07-27 feature-flag removal note for precedent), the following describe
subsystems this change fully removes and are left as-is rather than edited or
deleted: `2026-07-05-macos-auth-and-scoping.md`, `2026-07-05-macos-google-signin.md`,
`2026-07-06-macos-firestore-share.md`, `2026-07-14-macos-account-deletion.md`,
`2026-07-15-macos-email-capture-and-support.md`, and `2026-07-11-macos-onboarding.md`
(the old two-path onboarding flow this note's "What replaced it" section above
supersedes).

The following docs describe features that **persist** but contain Firestore/auth
details that are now stale — not rewritten in place (same dated-note convention),
but flagged here so a reader doesn't mistake the leftover mentions for current
behavior: `2026-07-10-macos-offline-mode.md` (decision 5, the Firestore
cross-device sync), `2026-07-16-macos-post-session-retranscription.md` (the
resync-to-shared-doc step), `2026-07-29-macos-live-line-building.md` (its
Firestore write-cadence subsection), `2026-07-29-macos-speaker-auto-naming.md`
(the cloud-doc mirror step), `2026-08-04-macos-openrouter-summaries.md` (its
verification steps mention a Firestore mirror update), `2026-07-31-macos-markdown-export.md`
(one parenthetical), `2026-08-04-session-list-speaker-names.md` (decision 4's
"Firestore backfill parity" rationale), `2026-07-15-macos-name-mention-highlight-notify.md`
(its name source is now `LiveSessionStore.yourName`, not `MacAuthManager`), and
`2026-07-28-macos-custom-vocabulary.md` (the "signed-in display name" context
ingredient is now the local Your Name preference).
