# macOS Account Deletion (OpenCaptions)

> **Historical — superseded by `docs/2026-08-10-remove-accounts-and-firestore.md`.** Account
> deletion is moot — there is no account system left to delete an account from (#33). Kept for
> historical context only.

**Date:** 2026-07-14
**Status:** Implemented

## Why

Apple App Store Review Guideline **5.1.1(v)** requires any app that supports account
creation to also offer **in-app account deletion**. Open Captions creates accounts (Google /
email-password / Apple) but had no deletion path — a hard blocker for shipping to the Mac
App Store. This was an explicit pre-launch deferral.

## What ships

A confirmation-gated **Delete Account** action in **Settings → Account** (next to Sign Out,
signed-in users only). It re-authenticates, deletes the Firebase Auth user, revokes the Apple
token (Apple users), wipes this user's local data, and returns the app to onboarding/sign-in.

## Key decisions

### Scope: the app deletes only Auth + local data; the backend cleans itself up
The client deletes the **Firebase Auth user** and this user's **local SwiftData rows + on-disk
audio**. It does **not** touch Firestore. Database/backend cleanup is a Cloud Function
concern: the backend Cloud Functions project deploys an Auth `onDelete` trigger
(`onUserDeleted`, region `asia-southeast1`, in `src/onUserDelelted.ts`) that fires when the
Auth user is removed and deletes the user's **RevenueCat customer** (the shared "Min"
balance). The client deliberately deletes only Auth + local. Keeping the client simple
avoids duplicating cleanup logic and needing extra Firestore client-delete permissions.

> **Follow-up (out of scope, backend Cloud Functions project):** `onUserDeleted` does **not** currently purge the
> user's share-to-web Firestore session docs. If that's wanted, extend the existing trigger in
> the backend Cloud Functions project (branch off its `main`, emulator-test) — it is not an app change.

### Proactive per-provider re-authentication
Firebase's `user.delete()` throws `requiresRecentLogin` when the session is stale, and Apple
token revocation needs a **fresh** `authorizationCode` regardless. So we re-authenticate up
front rather than lazily, dispatching on `user.providerData.first?.providerID`:

| Provider | Re-auth mechanism |
|---|---|
| **Email/password** (`EmailAuthProvider.id`) | `SecureField` password → `EmailAuthProvider.credential(withEmail:password:)` |
| **Google** (`GoogleAuthProvider.id`) | Silent `GIDSignIn.restorePreviousSignIn()` (refresh if `idToken` nil) → interactive `signIn(withPresenting:)` fallback → `GoogleAuthProvider.credential(...)` |
| **Apple** (`"apple.com"`) | SwiftUI `SignInWithAppleButton` in the sheet → `OAuthProvider.appleCredential(withIDToken:rawNonce:fullName:)` + capture `authorizationCode` for `revokeToken` |

The password field / Google web flow / Apple sheet each double as the identity proof for the
destructive action. Order: reauth → **(Apple) `revokeToken` → `user.delete()`** → local wipe
→ `signOut()`.

> **Revoke must precede delete.** `Auth.revokeToken(...)`
> authorizes its request with the **current user's ID token** (verified against the
> firebase-ios-sdk source: it calls `currentUser?.internalGetToken`). After `user.delete()` there is
> no `currentUser`, so a revoke *after* delete silently fails — a
> delete-then-revoke order never actually revokes the Apple token. Revoking first (and letting a
> revoke failure block deletion) guarantees the token is revoked whenever the account is
> removed (App Review 5.1.1). For Google/email there is no token to revoke, so this step is
> skipped and `delete()` is effectively first.

**Apple is defensive today.** Its sign-in button is hidden because Firebase rejects the
ID-token audience for the dev's custom bundle id; reauth hits the same audience check, so
there are effectively no Apple-provider users on the current build. The branch is
implemented for when the button is re-enabled under a proper team/bundle id.

### Anti-accident confirmation gate
Because deletion is permanent, the destructive control stays **disabled** until the user types
the exact phrase **`delete my account`** *and* their **account email** (both trimmed,
case-insensitive). The sheet leads with explicit data-loss / irreversible warnings.

### Precise, shared-Mac-safe local wipe
We fetch this uid's `TranscriptionSession`s, harvest their `audioFileName`s, delete each
session via `context.delete(_:)`, `save()`, then `SessionAudioStore.delete(fileName:)` each
file. **Per-object deletes** (not the store-level batch `delete(model:where:)`) are used
because the object-graph delete reliably fires the `.cascade` rule to `TranscriptionLine` +
`ActionItem` — a batch delete on a manually-created `ModelContext` (autosave off) can skip the
cascade and orphan the transcript text. On-disk audio (`SessionAudio/<uuid>.m4a`; only the
filename is persisted) is not covered by the cascade, hence the explicit file cleanup. Only
this uid's rows/audio are touched — another signed-out user's data on a shared Mac survives.

### Returning to sign-in is free
The flow ends in `MacAuthManager.signOut()`, which clears `userID` and sets `guestMode=false`.
`OpenCaptionsApp`'s gate (`hasCompletedOnboarding && (auth.isSignedIn || isGuestMode)`) then falls
to `MacOnboardingView`. `signOut()` also already tears down billing (`discardActiveSession` +
`clearPendingDeduction` + RevenueCat `logOut`). The delete sheet observes `auth.isSignedIn`
flipping false to dismiss and close the Settings window (same idiom as Sign Out).

## Files

- `OpenCaptions/Utility/Auth/MacAuthManager.swift` — added observable `isDeleting` / `deletionError`.
- `OpenCaptions/Utility/Auth/MacAuthManager+AccountDeletion.swift` — **new.** `MacAuthProviderKind`,
  `MacDeletionReauth`, `MacDeletionError`, `deleteAccount(reauth:modelContainer:)`, Google
  silent/interactive reauth, and the local+audio wipe.
- `OpenCaptions/Views/Settings/MacDeleteAccountSheet.swift` — **new.** Confirmation-gated,
  provider-aware sheet.
- `OpenCaptions/Views/Settings/MacAccountSettingsView.swift` — Delete Account button (signed-in
  pane) + sheet presentation.
- `OpenCaptions/Views/Settings/MacSettingsView.swift` — header/comment tidy.

## Notes / deferrals
- Strings are hardcoded English (Open Captions has no `LanguageManager`).
- Password reset / email verification remain deferred.
