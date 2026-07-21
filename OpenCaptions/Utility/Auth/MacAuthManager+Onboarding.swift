//
//  MacAuthManager+Onboarding.swift
//  OpenCaptions
//
//  Onboarding completion + account-mode state, built on a per-user pattern with
//  a macOS "use without an account" (offline guest) path.
//
//  Persistence model (see docs/2026-07-11-macos-onboarding.md):
//  • Global `hasCompletedOnboarding` (Bool) — the gate flag. The app shows the
//    main UI only when it's set AND the user is signed in OR a guest.
//  • Per-owner `"{owner}_hasCompletedOnboarding"` — so a returning signed-in user
//    skips onboarding and, on a shared Mac, a *different* new user still sees it.
//    Owner is the Firebase uid, or the `"local"` sentinel for a guest.
//  • `guestMode` (Bool) — distinguishes a deliberate offline guest (enter the app)
//    from a signed-out / token-expired cloud user (must re-authenticate).
//
//  A guest is force-locked to the on-device engine (offline), so the metered
//  cloud path — whose balance gate fails open when RevenueCat isn't configured —
//  is never reachable without an account.
//

import Foundation

extension MacAuthManager {

    /// Sentinel owner id for a local guest (no Firebase account). Chosen so guest
    /// sessions save under a STABLE owner rather than `nil`: `nil`-owner rows are
    /// (a) invisible to the uid-scoped list and (b) claimed by the first account to
    /// sign in on this Mac (`SessionOwnerBackfill`). A sentinel avoids both.
    static let guestOwnerId = "local"

    /// The effective owner id for per-user scoping: the Firebase uid when signed
    /// in, else the guest sentinel. Used by the history query, the session-save
    /// path, and the detail-view ownership guard so read and write always agree.
    var ownerId: String { userID ?? Self.guestOwnerId }

    /// A local guest = finished onboarding without an account (offline-only). The
    /// app gate itself reads the underlying `@AppStorage` flags directly (so it
    /// re-renders on change); this computed is for non-view callers.
    var isGuest: Bool {
        !isSignedIn && UserDefaults.standard.bool(forKey: LiveSessionStore.guestModeKey)
    }

    /// Per-owner onboarding-completion key.
    func onboardingKey(for owner: String) -> String { "\(owner)_hasCompletedOnboarding" }

    /// Marks onboarding complete and records the chosen account mode. Called once,
    /// from the onboarding flow's final step.
    /// - Parameter guest: true for the offline "no account" path — locks the app to
    ///   the on-device engine; false for the signed-in cloud path.
    func completeOnboarding(guest: Bool) {
        let defaults = UserDefaults.standard
        let owner = guest ? Self.guestOwnerId : ownerId
        defaults.set(true, forKey: LiveSessionStore.hasCompletedOnboardingKey)
        defaults.set(true, forKey: onboardingKey(for: owner))
        defaults.set(guest, forKey: LiveSessionStore.guestModeKey)
        // A guest is locked to the free on-device engine; a fresh cloud user defaults
        // to cloud transcription (the reason they signed in).
        defaults.set(guest, forKey: LiveSessionStore.offlineModeKey)
    }

    /// Mirrors the per-user onboarding flag into the global gate flag whenever a
    /// real account signs in (or is restored at launch), and clears guest mode —
    /// an account supersedes the local-guest state. Called from `saveUserID`, so it
    /// runs on every sign-in path and launch restore.
    ///
    /// This is what makes a returning signed-in user skip onboarding while a *new*
    /// user on the same Mac still sees it: the global flag becomes whatever THIS
    /// uid's per-user flag says, not whatever the last user left behind.
    func mirrorOnboardingState(for uid: String) {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: onboardingKey(for: uid))
        defaults.set(completed, forKey: LiveSessionStore.hasCompletedOnboardingKey)
        defaults.set(false, forKey: LiveSessionStore.guestModeKey)
    }

    #if DEBUG
    /// DEBUG-only: wipes onboarding-completion state so the setup assistant runs
    /// again on the next gate evaluation. Clears the global flag, guest mode, and
    /// the per-owner keys for the current account and the local guest. The gate's
    /// `@AppStorage` observes these, so the UI returns to onboarding immediately.
    /// Call while `userID` is still set (e.g. before sign-out clears it) so the
    /// signed-in account's per-owner flag is cleared too.
    func resetOnboardingState() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: LiveSessionStore.hasCompletedOnboardingKey)
        defaults.set(false, forKey: LiveSessionStore.guestModeKey)
        defaults.removeObject(forKey: onboardingKey(for: Self.guestOwnerId))
        if let uid = userID { defaults.removeObject(forKey: onboardingKey(for: uid)) }
    }
    #endif
}
