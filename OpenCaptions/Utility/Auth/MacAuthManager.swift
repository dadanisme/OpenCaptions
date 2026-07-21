//
//  MacAuthManager.swift
//  OpenCaptions
//
//  Authentication for the standalone macOS app
//  (Sign in with Apple → Firebase, email/password, launch reconcile), minus the
//  RevenueCat / Analytics / onboarding pieces — none of which exist on macOS.
//
//  Sign-in itself lives in the +Apple / +Email extensions.
//

import AuthenticationServices
import FirebaseAuth
import Foundation

@Observable
@MainActor
final class MacAuthManager {

    static let shared = MacAuthManager()

    // MARK: - Identity (observed by the app gate + profile UI)

    private(set) var userID: String?
    private(set) var userName: String?
    private(set) var userEmail: String?
    private(set) var photoURL: URL?

    var isSignedIn: Bool { userID != nil }

    // MARK: - Account-deletion state (observed by the delete sheet)

    /// True while a delete-account flow is running (reauth → delete → wipe). Drives
    /// the sheet's progress + disables its controls. See MacAuthManager+AccountDeletion.
    var isDeleting = false
    /// Last delete-account failure, surfaced inline in the delete sheet. Nil clears it.
    var deletionError: String?

    // MARK: - UserDefaults keys

    let userIDKey = "cached_firebase_user_id"
    let appleUserIDKey = "cached_apple_user_id"
    private let userNameKey = "userName"
    private let userEmailKey = "userEmail"
    private let photoURLKey = "userPhotoURL"

    /// Firebase auth-state listener handle; kept so registration stays idempotent.
    private var authListener: AuthStateDidChangeListenerHandle?

    private init() {
        userID = UserDefaults.standard.string(forKey: userIDKey)
        userName = UserDefaults.standard.string(forKey: userNameKey)
        userEmail = UserDefaults.standard.string(forKey: userEmailKey)
        if let stored = UserDefaults.standard.string(forKey: photoURLKey) {
            photoURL = URL(string: stored)
        }
    }

    // MARK: - Firebase auth-state listener

    /// Registers a Firebase auth-state listener that mirrors the signed-in user's
    /// profile (name, email, photo) into the local cache. This is the source of
    /// truth for the display name: Sign in with Apple only delivers the full name
    /// on the FIRST authorization, so on every later login the credential's name is
    /// nil — but Firebase persists the `displayName` we committed the first time, so
    /// reading it back here keeps the name from "disappearing". Idempotent: safe to
    /// call from `App.init` and again on window recreation.
    func startListening() {
        guard authListener == nil else { return }
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let user else { return }
            // Read the profile fields here (the Firebase `User` isn't Sendable, so
            // don't carry it across the actor hop) and apply the plain values.
            let uid = user.uid
            let name = user.displayName
            let email = user.email
            let photo = user.photoURL
            Task { @MainActor [weak self] in
                self?.applyFirebaseProfile(uid: uid, name: name, email: email, photo: photo)
            }
        }
    }

    /// Backfills the cached identity from a Firebase profile. Only overwrites a
    /// field when Firebase actually has a value, so a provider that omits one (e.g.
    /// Apple has no photo) never clears a good cached value from another sign-in.
    private func applyFirebaseProfile(uid: String, name: String?, email: String?, photo: URL?) {
        saveUserID(uid)
        if let name, !name.isEmpty { saveUserName(name) }
        if let email, !email.isEmpty { saveUserEmail(email) }
        if let photo { savePhotoURL(photo) }
        // Scope RevenueCat (the shared "Min" minute balance) to this Firebase uid.
        // Runs on every sign-in AND launch restore — this listener fires for both —
        // and is idempotent (configures once, logs in thereafter).
        MacSubscriptionManager.shared.configure(userID: uid)
    }

    // MARK: - Launch reconcile

    /// Verifies cached credentials at launch. An Apple session caches an Apple
    /// user id whose credential state can flip to revoked/notFound in System
    /// Settings, so that must be re-checked; an email session has no Apple id and
    /// restores straight from Firebase's persisted session.
    func checkExistingCredential() async {
        if let cachedAppleID = UserDefaults.standard.string(forKey: appleUserIDKey) {
            let provider = ASAuthorizationAppleIDProvider()
            do {
                let state = try await provider.credentialState(forUserID: cachedAppleID)
                switch state {
                case .revoked, .notFound:
                    signOut()
                    return
                default:
                    break
                }
            } catch {
                print("❌ Credential check error: \(error)")
            }
        }

        if Auth.auth().currentUser == nil, userID != nil {
            // We cached a uid but Firebase has no session (token invalidated) —
            // clear the stale cache so the app gate shows the sign-in screen.
            signOut()
        }
        // When a Firebase session DOES exist, the auth-state listener
        // (`startListening`) mirrors the name/email/photo into the cache — including
        // the Apple display name that the credential omits on repeat logins.
    }

    // MARK: - Sign out

    /// Ends the auth session and clears the cached identity. Deliberately does
    /// NOT touch SwiftData: the scoped `@Query` hides the previous user's rows on
    /// rebuild, and their sessions stay on disk for when they sign back in.
    func signOut() {
        // Stop any live session FIRST (see LiveSessionStore.discardActiveSession): a
        // window-independent metered session would otherwise keep running past
        // sign-out and, via re-sign-in's refresh, flush its minutes against the next
        // user. Then drop any unflushed pending (never charge the next user) and log
        // RevenueCat out so the shared "Min" balance isn't read for a stale uid.
        LiveSessionStore.shared.discardActiveSession()
        MacSubscriptionManager.shared.clearPendingDeduction()
        MacSubscriptionManager.shared.logOut()
        #if DEBUG
        // DEBUG builds re-trigger onboarding on sign-out so the whole flow is easy
        // to re-test. Runs BEFORE clearCache() while `userID` is still set, so the
        // account's per-owner flag is cleared too. Release keeps onboarding done —
        // the gate handles the signed-out state without replaying the flow.
        resetOnboardingState()
        #endif
        try? Auth.auth().signOut()
        clearCache()
        // Defensive: an account is never also a guest, but never leave the offline
        // guest flag set after a sign-out — the gate would otherwise treat the
        // signed-out user as a guest instead of routing them back to onboarding.
        UserDefaults.standard.set(false, forKey: LiveSessionStore.guestModeKey)
    }

    private func clearCache() {
        userID = nil
        userName = nil
        userEmail = nil
        photoURL = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: userIDKey)
        defaults.removeObject(forKey: appleUserIDKey)
        defaults.removeObject(forKey: userNameKey)
        defaults.removeObject(forKey: userEmailKey)
        defaults.removeObject(forKey: photoURLKey)
    }

    // MARK: - Persistence helpers (shared by the +Apple / +Email extensions)

    func saveUserID(_ id: String) {
        userID = id
        UserDefaults.standard.set(id, forKey: userIDKey)
        // Mirror this account's onboarding-completion into the global gate flag and
        // drop any local-guest state — a real account supersedes it. Runs on every
        // sign-in path and launch restore (see MacAuthManager+Onboarding).
        mirrorOnboardingState(for: id)
    }

    func saveUserName(_ name: String) {
        userName = name
        UserDefaults.standard.set(name, forKey: userNameKey)
    }

    /// Updates the display name on the Firebase Auth profile, then mirrors it into
    /// the local cache on success. Throws on failure (offline / auth error) so the
    /// caller can surface it without clobbering the cached name.
    func updateDisplayName(_ name: String) async throws {
        guard let user = Auth.auth().currentUser else { return }
        let request = user.createProfileChangeRequest()
        request.displayName = name
        try await request.commitChanges()
        saveUserName(name)
    }

    func saveUserEmail(_ email: String) {
        userEmail = email
        UserDefaults.standard.set(email, forKey: userEmailKey)
    }

    func savePhotoURL(_ url: URL) {
        photoURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: photoURLKey)
    }
}

/// Errors surfaced by the sign-in flows.
enum MacAuthError: LocalizedError {
    case invalidAppleToken
    case missingGoogleClientID
    case invalidGoogleToken

    var errorDescription: String? {
        switch self {
        case .invalidAppleToken:
            return "Couldn't read the Apple identity token. Please try again."
        case .missingGoogleClientID:
            return "Google sign-in isn't configured (missing client id). Check GoogleService-Info.plist."
        case .invalidGoogleToken:
            return "Couldn't read the Google identity token. Please try again."
        }
    }
}
