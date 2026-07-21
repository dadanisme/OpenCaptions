# macOS Auth (Apple + Email) & Per-User Data Scoping

**Date:** 2026-07-05
**Issue:** #180 (epic #103) — "macOS: Sign in with Apple and per-user data scoping"
**Target:** `OgmoMac` (standalone native macOS app)

## Problem

The OgmoMac MVP (#171) shipped with no authentication: every session saved with
`userId == nil` and the sidebar listed all local sessions unscoped. #180 asks to
bring the iOS auth story to the Mac — Sign in with Apple + Firebase UID + per-user
scoping. Product added a second requirement: **email sign-in** alongside Apple, a
profile block pinned to the **bottom of the sidebar** (identity + logout), and
advanced account actions in a native **macOS Settings window**.

## The gating decision: adding Firebase to OgmoMac

The MVP was deliberately **system-frameworks-only — no Firebase, no RevenueCat, no
SPM** (`docs/2026-07-04-macos-standalone-mvp.md`). But **email sign-in requires an
identity backend**; there is no Apple-native email/password primitive. iOS already
does both Apple and email sign-in through **Firebase Auth**
(Apple → `OAuthProvider.appleCredential`; email → `Auth.signIn/createUser(withEmail:password:)`).

A native-Apple-only path (scope by `ASAuthorizationAppleIDCredential.user`, no
Firebase) would keep the zero-dependency posture but **cannot satisfy the email
requirement** and would put macOS UIDs in a different namespace than iOS.

**Decision:** add **`FirebaseAuth` only** to OgmoMac (it transitively pulls
`FirebaseCore`). No Firestore / Functions / Analytics / RevenueCat. This is the
minimum to satisfy #180, keeps macOS UIDs in the **same namespace as iOS** (same
Firebase project → shared user records), and lets the credential-exchange logic be
ported nearly verbatim. It reverses the MVP's "no Firebase" constraint — recorded
here and reflected in CLAUDE.md.

## Decisions

- **Require sign-in.** The window shows `SignInView` until signed in (mirrors iOS);
  no anonymous recording. So the scoped `@Query` always has a uid.
- **Advanced settings → macOS Settings window** (`Settings` scene, Cmd+,). The
  sidebar profile footer stays minimal (name/email + a cog that opens Settings);
  **Sign Out lives in Settings**, not the sidebar.
- **Deferred:** account deletion, password reset, email verification, RevenueCat /
  subscription, Firestore share-to-web, Analytics, and any onboarding flow. The
  Settings window is scaffolded (a `TabView` with one Account pane) so those slot in
  later without restructuring.

## Implementation notes

- **`MacAuthManager`** (`@Observable @MainActor` singleton, split across
  `MacAuthManager.swift` / `+Apple.swift` / `+Email.swift`) ports the iOS
  `AuthManager` minus RevenueCat/Analytics/onboarding. It reuses the **same
  UserDefaults keys** as iOS (`cached_firebase_user_id`, `cached_apple_user_id`,
  `userName`, `userEmail`).
- **Apple** uses SwiftUI's `SignInWithAppleButton` — its completion hands back the
  `ASAuthorization` directly, so the iOS `ASAuthorizationController` delegate +
  UIKit `presentationAnchor` plumbing is **not ported** (that anchor scans
  `UIApplication.connectedScenes`, which has no macOS equivalent). No `NSObject`
  base class needed.
- **Launch reconcile** only runs the `ASAuthorizationAppleIDProvider`
  `credentialState` revocation check when a `cached_apple_user_id` exists (email
  sessions have none); otherwise it restores `Auth.auth().currentUser`.
- **Sign out** clears the auth cache only — it must **not** wipe SwiftData; the
  scoped `@Query` hides the previous user's rows on rebuild, and their sessions
  remain on disk. There is no user switcher (sign-out → sign-in, like iOS).
- **Per-user scoping** mirrors iOS: `TranscriptionsScreen` takes `init(userId:)` and
  builds a `#Predicate { $0.userId == userId }` query; the uid is stashed on
  `TranscriberModel.ownerUserId` at `start()` and stamped at **both** save sites
  (final save on Stop, and the mid-session flush for long recordings).
  `SessionOwnerBackfill` (ported verbatim) claims pre-auth `userId == nil` sessions
  for the first signed-in user at launch. `MacSessionDetailView` carries a
  defense-in-depth ownership guard.

## Build / provisioning (one-time, done outside code)

- **`OgmoMac.entitlements`**: added `com.apple.developer.applesignin` = `["Default"]`
  and `keychain-access-groups` = `["$(AppIdentifierPrefix)com.wentao.unmute.OgmoMac"]`.
  The keychain group is **required** — under App Sandbox, FirebaseAuth's keychain
  persistence fails with `errSecMissingEntitlement (-34018)` without it.
  (`$(AppIdentifierPrefix)` resolves to the signing team's prefix, so this works
  under a local placeholder team too.)
- **`project.pbxproj`**: `FirebaseAuth` linked to the OgmoMac target (per-target
  `XCSwiftPackageProductDependency` + `PBXBuildFile`; the `firebase-ios-sdk` package
  ref already existed at project level).
- **Firebase console** (shared `ogmo-491906` project, same as iOS): the prod Apple
  app is registered under bundle id `com.wentao.unmute.OgmoMac`; its
  `GoogleService-Info.plist` is dropped into `OgmoMac/` (git-ignored). The **Apple**
  and **Email/Password** providers must be enabled.
- **Apple Developer**: enable **Sign in with Apple** on App ID
  `com.wentao.unmute.OgmoMac` under team **`YN8NVQ69WY`** (shared with the iOS target).

### Bundle id / team: prod vs local placeholder

Prod OgmoMac signs as **`com.wentao.unmute.OgmoMac`** under team **`YN8NVQ69WY`**
(shared with iOS). A developer without access to that team may **locally** override
the target's `DEVELOPMENT_TEAM` + `PRODUCT_BUNDLE_IDENTIFIER` in `project.pbxproj` to
their own account (e.g. `com.muhammadramdan.unmute.OgmoMac` / `C4SQMCY5WT`) to build
and run — this change stays **uncommitted**. With the prod `GoogleService-Info.plist`
(registered under `com.wentao…`), Firebase logs a harmless bundle-id-mismatch warning
under a placeholder id, and **email/password sign-in works regardless**. Sign in with
Apple validates the identity token's `aud` claim against a bundle id registered in the
Firebase project, so under a placeholder id it will be rejected unless that id is also
registered as an Apple app in the project — use email sign-in to test locally, or
register the placeholder id too.
