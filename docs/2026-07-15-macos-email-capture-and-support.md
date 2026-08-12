# macOS: Email capture + marketing consent, and a Support section

> **Historical — superseded.** The email-capture/marketing-consent half was removed entirely
> with the rest of the account system (`docs/2026-08-10-remove-accounts-and-firestore.md`,
> #33). The Support section this note also describes has since moved into a segmented-Picker
> Settings pane with no signed-in-email diagnostics
> (`docs/2026-08-10-macos-settings-navsection.md`) — nothing below reflects the current
> Settings structure. Kept for historical context only.

**Date:** 2026-07-15 · **Scope:** OpenCaptions (native macOS) only

Two related additions to the macOS Settings scene (`MacSettingsView`, Cmd+,).

## Always capture user email (+ marketing consent)

### Key realization: email is already captured
The email does **not** need to be mirrored to Firestore. Firebase **Auth** already stores it for every provider (Google returns it, email/password inherently has it, and Apple returns whatever the user allows). The *user record* the issue refers to is the Firebase Auth account. So the email-capture half of this work reduces to one thing: **make sure Sign in with Apple requests the email scope** so Apple returns an email rather than nothing.

That was **already implemented** — every Apple entry point sets `request.requestedScopes = [.fullName, .email]`:
- `MacSignInControls.swift` (onboarding + guest-upgrade sheet)
- `MacDeleteAccountSheet.swift` (reauth for deletion)

Requesting the scope is the maximum an app can do: the user can still choose "Hide My Email" in Apple's own sheet — that's Apple UX, not app-overridable. When hidden, Apple returns a **deliverable** `@privaterelay.appleid.com` address, which Firebase Auth stores like any other. So no code change was needed for email capture.

> An earlier revision of this change mirrored the email into `users/{uid}.email`. That was **removed** — it duplicated data Firebase Auth already holds. The backend joins consent (below) to the auth email by uid.

### What changed: marketing consent only
**Marketing consent (`users/{uid}.marketingOptIn`).** A new "Communications" section in Settings → Account (signed-in pane only — guests have no account) with an **opt-in** toggle (defaults **off**, GDPR/App-Review-friendly). The toggle loads its current value from Firestore via `fetchMarketingOptIn()` and writes changes via `syncMarketingOptIn(_:)`. It uses a **custom `Binding`** whose setter fires only on user interaction, so the async `.task` that loads the initial value never triggers a write-back. Consent lives in Firestore because Firebase Auth can't store an arbitrary app field — and it's genuinely new data, not a duplicate of anything.

### Audit fields on the user doc
No Cloud Function seeds `users/{uid}` (`onUserCreated` only provisions RevenueCat), so the **client creates the doc lazily on its first write**. Both macOS `users/{uid}` writes (marketing consent, offline mode) now funnel through one private helper, `FirestoreSyncService.mergeUserDoc(_:)`, which:
- always stamps `updatedAt`/`updatedBy`, and
- stamps `createdAt`/`createdBy` **once** — only when a `getDocument` read *definitively* returns a non-existent doc. On a read error (e.g. offline) it skips the created-fields rather than risk clobbering an existing server-side `createdAt` when the queued merge later syncs.

This is why `syncOfflineMode` was refactored to route through the same helper (previously it merged `updatedAt`/`updatedBy` only, assuming some other writer had created the doc — which nothing did).

### Firestore rules
No change needed. `match /users/{userId} { allow read, write: if request.auth.uid == userId }` in the backend Cloud Functions project's `firestore.rules` already lets the owner write arbitrary fields.

## Support section

A new **Support** tab in `MacSettingsView`'s `TabView` (`MacSupportSettingsView`), placed **before** the conditional Usage tab (which must stay last — a middle conditional tab drops a sibling's icon on macOS). Three actions, each opening the default mail client via a prefilled `mailto:` to a single inbox, **the support inbox (SUPPORT_EMAIL)** (distinguished by subject):

- **Send Feedback** — subject "Open Captions for Mac - Feedback".
- **Report a Problem** — subject "Open Captions for Mac - Bug Report", body prefilled with a description prompt plus diagnostics (app version + build, macOS version, signed-in email + uid) for triage.
- **Contact Support** — subject "Open Captions for Mac - Support".

A version/OS footer shows the same diagnostics inline. `mailto:` URLs are built with `URLComponents` (correct percent-encoding of spaces/newlines) and opened with `NSWorkspace.shared.open`.

The Support tab is unconditional (available to offline guests too); for a guest the bug-report diagnostics read "not signed in".

## Follow-up (backend Cloud Functions project)
The *consumption* side — segmenting users by `marketingOptIn` (Firestore) joined to the **email from Firebase Auth** (Admin SDK) by uid, and actually sending mail — lives in the backend and is tracked in the backend Cloud Functions project. No email is stored in Firestore for this.

## Deferred / not done
- Localization: macOS UI strings (including these) remain hardcoded English (no `LanguageManager` on macOS yet), consistent with the rest of Open Captions.
- No email mirrored to Firestore and no editable "contact email" (both considered, dropped — the email already lives in Firebase Auth; only consent needed a home).
