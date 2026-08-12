# macOS Firestore share-to-web

> **Historical — superseded by `docs/2026-08-10-remove-accounts-and-firestore.md`.** Firestore
> live-session mirroring and password-protected share-to-web were removed entirely (#33) when
> the backend was dropped. Kept for historical context only.

Adds the "Share Session" feature to Open Captions (`OpenCaptions/`):
live Firestore mirroring, a finished-session share link, and password protection.
Before this, the app recorded, transcribed, saved locally, and
summarized, but never touched Firestore.

Analytics is out of scope here and tracked separately. `FirebaseAnalytics` is deliberately
**not** linked to the target by this change.

## What shipped

- **Firebase products**: added `FirebaseFirestore` + `FirebaseFunctions` to the
  OpenCaptions target in the Xcode project's `project.pbxproj` (the `firebase-ios-sdk`
  package ref was already present at project level; only per-target product
  dependencies + build-file entries were added, reusing the `FBA…` id scheme the
  existing OpenCaptions `FirebaseAuth` entry uses).
- **Services** (kept under the 250-line file
  limit via extension splits):
  - `FirestoreSyncService` (+`+Writes`/`+SessionSync`/`+LineSync`) — the live
    mirror. Wire format: session doc at
    `users/{uid}/sessions/{cloudSessionId}`, per-bubble `lines/{lineId}` docs
    (6-digit zero-padded), a public `sessionIndex/{id}` lookup, and a throttled
    `accumulator` field (1 write/sec) for the in-flight preview.
  - `SessionLinkSharer` — promotes a finished SwiftData session to a public doc.
  - `SessionPasswordService` — the `setSessionPassword`/`removeSessionPassword`
    callables (region `asia-southeast1`).
  - ~~`FeatureFlagService` + `FeatureFlag` — the remote flag reader (see below).~~
    **Removed 2026-07-27** — see `docs/2026-07-27-remove-feature-flags.md`.
- **Lifecycle wiring** in `MacTranscriptionViewModel` (new `+Firestore`
  extension + hooks): share mints the cloud session and backfills the transcript;
  line commits, partial previews, pause/resume, speaker renames, and stop/discard/
  fail all mirror to Firestore. `SummaryViewModel` pushes a fresh summary to the
  shared doc. `OpenCaptionsApp` reconciles orphaned live docs at launch (it also
  started the flag listener until the flag system was removed on 2026-07-27).
- **UI (share dialog)**: both the live-recording toolbar Share button and the
  saved-session detail "Share…" menu item mint/reuse the shared session and open
  a single `MacShareSessionSheet` — the public `<SESSION_SHARE_BASE_URL>/{id}`
  link with a Copy button, plus password controls (set / change / remove) that
  load the current server-owned state on open.
- **Menu-bar status**: the menu-bar dropdown shows recording state only, with no
  elapsed timer — a native `.menu` `MenuBarExtra` can't live-refresh while open,
  so a static "00:00" readout was misleading and was removed.

## Decisions

### Mac-specific feature flag: `Mac_session_sharing`

> **Superseded (2026-07-27)** — the remote feature-flag system was removed;
> sharing is now always enabled and there is no flag guard, no kill switch, and
> no `config/featureFlags` read. The rationale below is kept as the historical
> record of why the key was Mac-scoped. See
> `docs/2026-07-27-remove-feature-flags.md`.

Open Captions reads its own Firestore flag key **`Mac_session_sharing`** rather than
a shared `session_sharing` key, so sharing can be toggled independently per
platform (e.g. disable Mac sharing during a rollout). The
compile-time default is `true`, so the feature works before the backend adds the
key; the flag map lives in the same `config/featureFlags` doc. The Mac
`FeatureFlag` enum ships only the one case it needs (no `ttsInput`/`liveActivity`/
`engineSelector` — those features don't exist on the Mac), and `FeatureFlagService`
uses a Mac-distinct cache key (`mac_featureFlagsCache`).

The `sessionSharing` kill switch: every routine write funnelled through the flag
guard in `createDoc`/`updateDoc`, and flipping the flag off mid-session
gracefully sealed the live doc to `ended` via the one guard-bypassing
`forceUpdate`. (Removed 2026-07-27 — the guards are gone, every write goes
through unconditionally, and `forceUpdate` went with them since there is no
longer a guard to bypass.)

### `currentUid()` → `MacAuthManager`

`currentUid()` reads
`Auth.auth().currentUser?.uid ?? MacAuthManager.shared.userID`.

### Share dialog UX

No `NSSharingServicePicker`. Sharing opens a small `MacShareSessionSheet` with a
copy-able link and inline password controls, rather than an instant
clipboard copy or a full share sheet. Opening the dialog mints the shared
session first (share is idempotent), since both the link and any password require
a `cloudSessionId`.

### English-only error strings

The Mac has no `LanguageManager`, so `SessionPasswordError` uses plain English
literals instead of `.localized` keys.

## No backend changes required

The wire format, Firestore paths, security rules, and Cloud Functions are all
unchanged — the Mac writes to the same paths as the same authenticated user, so
the backend Cloud Functions project needs no edit. The one optional backend touch
at the time was adding a `Mac_session_sharing` boolean to the
`config/featureFlags` doc's `flags` map; absent, it defaulted to `true`. **As of
2026-07-27 that doc is not read at all** — sharing is compiled in and always on.

## Follow-ups

- macOS Analytics events (tracked separately).
