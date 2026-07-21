# macOS Firestore share-to-web (issue #182)

Brings the iOS "Share Session" feature to the standalone macOS app (`OgmoMac/`):
live Firestore mirroring, a finished-session share link, and password protection.
Before this, the Mac MVP (#171) recorded, transcribed, saved locally, and
summarized, but never touched Firestore.

Analytics — the other half of the original #182 — was split into a separate
issue (#200) and is **not** included here. `FirebaseAnalytics` is deliberately
**not** linked to the Mac target by this change.

## What shipped

- **Firebase products**: added `FirebaseFirestore` + `FirebaseFunctions` to the
  OgmoMac target in `unmute.xcodeproj/project.pbxproj` (the `firebase-ios-sdk`
  package ref was already shared at project level; only per-target product
  dependencies + build-file entries were added, reusing the `FBA…` id scheme the
  existing OgmoMac `FirebaseAuth` entry uses).
- **Ported services** (near-verbatim from `unmute/`, kept under the 250-line file
  limit via the same extension splits):
  - `FirestoreSyncService` (+`+Writes`/`+SessionSync`/`+LineSync`) — the live
    mirror. Wire format is unchanged from iOS: session doc at
    `users/{uid}/sessions/{cloudSessionId}`, per-bubble `lines/{lineId}` docs
    (6-digit zero-padded), a public `sessionIndex/{id}` lookup, and a throttled
    `accumulator` field (1 write/sec) for the in-flight preview.
  - `SessionLinkSharer` — promotes a finished SwiftData session to a public doc.
  - `SessionPasswordService` — the `setSessionPassword`/`removeSessionPassword`
    callables (region `asia-southeast1`).
  - `FeatureFlagService` + `FeatureFlag` — the remote flag reader (see below).
- **Lifecycle wiring** in `MacTranscriptionViewModel` (new `+Firestore`
  extension + hooks): share mints the cloud session and backfills the transcript;
  line commits, partial previews, pause/resume, speaker renames, and stop/discard/
  fail all mirror to Firestore. `SummaryViewModel` pushes a fresh summary to the
  shared doc. `OgmoMacApp` starts the flag listener and reconciles orphaned live
  docs at launch.
- **UI (share dialog)**: both the live-recording toolbar Share button and the
  saved-session detail "Share…" menu item mint/reuse the shared session and open
  a single `MacShareSessionSheet` — the public `https://session.ogmo.app/{id}`
  link with a Copy button, plus password controls (set / change / remove) that
  load the current server-owned state on open.
- **Menu-bar status**: the menu-bar dropdown shows recording state only, with no
  elapsed timer — a native `.menu` `MenuBarExtra` can't live-refresh while open,
  so a static "00:00" readout was misleading and was removed.

## Decisions

### Mac-specific feature flag: `Mac_session_sharing`

The Mac reads its own Firestore flag key **`Mac_session_sharing`** rather than
reusing the iOS `session_sharing`, so sharing can be toggled independently per
platform (e.g. disable Mac sharing during a rollout without touching iOS). The
compile-time default is `true`, so the feature works before the backend adds the
key; the flag map lives in the same `config/featureFlags` doc. The Mac
`FeatureFlag` enum ships only the one case it needs (no `ttsInput`/`liveActivity`/
`engineSelector` — those features don't exist on the Mac), and `FeatureFlagService`
uses a Mac-distinct cache key (`mac_featureFlagsCache`).

The `sessionSharing` kill switch behaves exactly as on iOS: every routine write
funnels through the flag guard in `createDoc`/`updateDoc`, and flipping the flag
off mid-session gracefully seals the live doc to `ended` via the one
guard-bypassing `forceUpdate`.

### `currentUid()` → `MacAuthManager`

The only functional change to the ported `FirestoreSyncService` is
`currentUid()`, which reads `Auth.auth().currentUser?.uid ?? MacAuthManager.shared.userID`
instead of the iOS `AuthManager`.

### Share dialog UX

No `NSSharingServicePicker`. Sharing opens a small `MacShareSessionSheet` with a
copy-able link and inline password controls, rather than either an instant
clipboard copy or the iOS-style sheet. Opening the dialog mints the shared
session first (share is idempotent), since both the link and any password require
a `cloudSessionId`.

### English-only error strings

The Mac has no `LanguageManager`, so `SessionPasswordError` uses plain English
literals instead of the iOS `.localized` keys.

## No backend changes required

The wire format, Firestore paths, security rules, and Cloud Functions are all
unchanged — the Mac writes to the same paths as the same authenticated user, so
`../ogmo-cf` needs no edit. The only optional backend touch is adding a
`Mac_session_sharing` boolean to the `config/featureFlags` doc's `flags` map;
absent, it defaults to `true`.

## Follow-ups

- #200 — macOS Analytics events (split out of this issue).
