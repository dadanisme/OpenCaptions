# macOS Google Sign-In + committed personal signing identity

> **Historical — superseded by `docs/2026-08-10-remove-accounts-and-firestore.md`.** Google
> Sign-In was removed entirely (#33) along with the rest of the account system. Kept for
> historical context only.

**Date:** 2026-07-05
**Target:** OpenCaptions (standalone native macOS app)
**Related:** `docs/2026-07-05-macos-auth-and-scoping.md`

## Problem

Sign in with Apple on Open Captions fails at the Firebase exchange with:

> The audience in ID Token [com.…OpenCaptions] does not match the expected audience.

Firebase's Apple auth provider validates that the Apple ID token's `aud` (= the app's
bundle id) is a bundle id registered/trusted for the Firebase project. When a developer
builds under **their own bundle id** (not the one registered against the Firebase Apple
provider), the audience no longer matches and every Apple sign-in is rejected. This is a
per-bundle-id constraint specific to Sign in with Apple.

## Decision

1. **Add Google Sign-In as the primary macOS auth path.** Google Sign-In has no
   per-bundle-id audience constraint — any bundle id can complete the OAuth flow as long
   as the Firebase project has Google enabled and a matching OAuth client
   (`CLIENT_ID` / `REVERSED_CLIENT_ID` in `GoogleService-Info.plist`).
2. **Keep Sign in with Apple in the codebase but hide the button.** `SignInView` gates it
   behind `showAppleSignIn = false`; the `MacAuthManager+Apple` flow, nonce helpers, and
   entitlement are untouched. Flip the flag to restore it (e.g. once building under a
   bundle id registered with the Firebase Apple provider).
3. **Commit the personal signing identity.** The OpenCaptions target now ships with
   `DEVELOPMENT_TEAM = C4SQMCY5WT` and `PRODUCT_BUNDLE_IDENTIFIER = com.muhammadramdan.OpenCaptions`
   (Ramdan's account), which is the account that owns the Firebase app + Google OAuth
   client the committed `GoogleService-Info.plist` points at. This supersedes the earlier
   "developer overrides locally, uncommitted" convention for OpenCaptions.

## Implementation

- **SPM**: `GoogleSignIn-iOS` package (`https://github.com/google/GoogleSignIn-iOS`,
  upToNextMajor from 8.0.0), product **`GoogleSignIn`**, added to the OpenCaptions target only.
  The button is a compact custom control using a `GoogleLogo` SVG asset (the officially-branded
  `GoogleSignInButton` from `GoogleSignInSwift` was tried but its blue/white styling clashed
  with the app's dark theme).
- **`MacAuthManager+Google.swift`**: `signInWithGoogle(presenting: NSWindow)` →
  `GIDSignIn.sharedInstance.signIn(withPresenting:)` → `GoogleAuthProvider.credential` →
  `Auth.auth().signIn(with:)`, then persists identity like the Apple/email tails. Client id
  comes from `FirebaseApp.app()?.options.clientID` (nothing hardcoded).
- **`OpenCaptionsApp`**: `.onOpenURL { GIDSignIn.sharedInstance.handle($0) }` forwards the
  OAuth callback.
- **URL scheme**: `OpenCaptions-Info.plist` registers `CFBundleURLTypes` scheme
  `$(REVERSED_CLIENT_ID)`; the value is a `Config.xcconfig` key (git-ignored), kept out of
  committed files so a fork can supply its own without editing the plist.
- **Entitlements**: no change — `com.apple.security.network.client` (already present) covers
  the `ASWebAuthenticationSession` that GoogleSignIn uses on macOS.

## Trade-offs / follow-ups

- The committed default now depends on **one developer's** Firebase app + team. A
  contributor on a different team must locally override team + bundle id and drop in a
  matching `GoogleService-Info.plist` + `REVERSED_CLIENT_ID`.
- Sign in with Apple stays dark until the app builds under a bundle id registered with the
  Firebase Apple provider; then just flip `showAppleSignIn`.
