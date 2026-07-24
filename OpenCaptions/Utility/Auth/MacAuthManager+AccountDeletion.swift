//
//  MacAuthManager+AccountDeletion.swift
//  OpenCaptions
//
//  In-app account deletion — required for the Mac App Store (App Review Guideline
//  5.1.1(v)). macOS supports
//  THREE providers (Google, email/password, Apple), so the reauth step dispatches on
//  the current provider. The app deletes only the Firebase Auth user + this user's
//  LOCAL data; any backend cleanup is handled server-side by the
//  `onUserDeleted` Auth trigger in the backend Cloud Functions project. See
//  docs/2026-07-14-macos-account-deletion.md.
//
//  Apple requires token revocation for "Sign in with Apple" accounts (5.1.1); the
//  fresh authorizationCode for that comes from the same credential the delete sheet's
//  SignInWithAppleButton yields (single-use, ~5 min). Google reauth prefers a silent
//  Keychain restore, falling back to an interactive window when none is cached.
//

import AppKit
import AuthenticationServices
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import SwiftData

/// Which provider the signed-in Firebase user authenticated with — drives the delete
/// sheet's reauth UI (password field vs Apple button vs Google web flow).
enum MacAuthProviderKind {
    case google, apple, email, unknown
}

/// Fresh reauth material captured by the delete sheet, one case per provider. The
/// sheet builds the matching case after the user clears the confirmation gate.
enum MacDeletionReauth {
    case google
    case email(password: String)
    case apple(credential: ASAuthorizationAppleIDCredential, rawNonce: String)
}

/// Errors specific to the deletion flow. `cancelled` lets a provider's user-cancel
/// bubble up so `deleteAccount` can swallow it silently.
enum MacDeletionError: LocalizedError {
    case missingEmail
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingEmail: return "This account has no email on file to re-authenticate with."
        case .cancelled: return nil
        }
    }
}

extension MacAuthManager {

    // MARK: - Current provider

    /// The provider backing the signed-in Firebase user. Apple has no Swift id
    /// constant, so match the "apple.com" literal.
    var currentProviderKind: MacAuthProviderKind {
        let ids = Auth.auth().currentUser?.providerData.map(\.providerID) ?? []
        if ids.contains(GoogleAuthProvider.id) { return .google }
        if ids.contains("apple.com") { return .apple }
        if ids.contains(EmailAuthProvider.id) { return .email }
        return .unknown
    }

    // MARK: - Delete account

    /// Re-authenticate (fresh credential) → (Apple) revoke the token → delete the Firebase
    /// user → wipe this user's local data → sign out. Revoke precedes delete because it
    /// needs a live `currentUser` (step 2). If delete succeeds but a later step throws, we
    /// still sign out so the app never lingers "signed in" to a dead account.
    func deleteAccount(reauth: MacDeletionReauth, modelContainer: ModelContainer) async {
        guard let user = Auth.auth().currentUser else { signOut(); return }
        guard !isDeleting else { return }  // ignore a second submit while one is in flight
        isDeleting = true
        deletionError = nil

        let deletedUID: String? = user.uid
        var firebaseUserDeleted = false

        do {
            // 1. Reauthenticate with a fresh credential (Apple also yields a revoke code).
            var appleAuthCode: String?
            switch reauth {
            case .google:
                try await user.reauthenticate(with: reauthenticateWithGoogle())

            case .email(let password):
                guard let email = user.email, !email.isEmpty else { throw MacDeletionError.missingEmail }
                try await user.reauthenticate(
                    with: EmailAuthProvider.credential(withEmail: email, password: password))

            case .apple(let credential, let rawNonce):
                guard let tokenData = credential.identityToken,
                      let tokenString = String(data: tokenData, encoding: .utf8) else {
                    throw MacAuthError.invalidAppleToken
                }
                try await user.reauthenticate(with: OAuthProvider.appleCredential(
                    withIDToken: tokenString, rawNonce: rawNonce, fullName: credential.fullName))
                if let codeData = credential.authorizationCode {
                    appleAuthCode = String(data: codeData, encoding: .utf8)
                }
            }

            // 2. Apple only: revoke the token BEFORE deleting. revokeToken authorizes its
            //    request with the CURRENT user's ID token, so it must run while the account
            //    still exists — after delete() there is no currentUser and it fails.
            //    A revoke failure blocks deletion, so the Apple token is always
            //    revoked when the account goes — App Review 5.1.1.
            if let appleAuthCode {
                try await Auth.auth().revokeToken(withAuthorizationCode: appleAuthCode)
            }

            // 3. Delete the Firebase user (fires the server `onUserDeleted` trigger).
            try await user.delete()
            firebaseUserDeleted = true

            // 4. Wipe this user's local data, then clear the session (returns to onboarding).
            wipeLocalSessions(uid: deletedUID, modelContainer: modelContainer)
            signOut()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User dismissed the Apple sheet — not an error.
        } catch MacDeletionError.cancelled {
            // User dismissed the Google web sheet — not an error.
        } catch {
            deletionError = error.localizedDescription
            // The account was already deleted upstream — finish teardown so the app
            // doesn't linger on a dead account.
            if firebaseUserDeleted {
                wipeLocalSessions(uid: deletedUID, modelContainer: modelContainer)
                signOut()
            }
        }

        isDeleting = false
    }

    // MARK: - Local data wipe

    /// Deletes only THIS user's `TranscriptionSession`s and their on-disk audio.
    /// Fetches the sessions and deletes each via `context.delete(_:)` — the object-graph
    /// delete reliably fires the `.cascade` rule (removing `TranscriptionLine` +
    /// `ActionItem`), whereas the store-level batch `delete(model:where:)` can skip the
    /// cascade on a manually-created context. Audio filenames are harvested from the same
    /// fetch: the SwiftData cascade covers relationships, not external files. Shared-Mac
    /// safe — another user's rows/audio are untouched.
    private func wipeLocalSessions(uid: String?, modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        do {
            let descriptor = FetchDescriptor<TranscriptionSession>(
                predicate: #Predicate { $0.userId == uid })
            let sessions = try context.fetch(descriptor)
            let audioNames = sessions.compactMap(\.audioFileName)
            sessions.forEach { context.delete($0) }
            try context.save()
            audioNames.forEach { SessionAudioStore.delete(fileName: $0) }
        } catch {
            print("⚠️ Local session wipe failed: \(error)")
        }
    }

    // MARK: - Google reauth (silent restore → interactive fallback)

    /// A fresh Google→Firebase credential for `reauthenticate(with:)`. Tries a silent
    /// Keychain restore first (no UI), then falls back to an interactive window.
    private func reauthenticateWithGoogle() async throws -> AuthCredential {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw MacAuthError.missingGoogleClientID
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        // Silent path — restorePreviousSignIn throws when nothing is cached, so any
        // failure cleanly falls through to the interactive prompt.
        if let credential = try? await restoredGoogleCredential() { return credential }

        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            throw MacAuthError.invalidGoogleToken
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
            return try googleCredential(from: result.user)
        } catch let error as NSError
            where error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.canceled.rawValue {
            // GIDSignInErrorCode is an NS_ERROR_ENUM (bridged as Int), so match the
            // domain + rawValue rather than a typed catch.
            throw MacDeletionError.cancelled
        }
    }

    /// Restores the cached Google session and builds a credential. A successful restore
    /// can still return a user whose `idToken` is nil, so refresh before use.
    private func restoredGoogleCredential() async throws -> AuthCredential {
        var user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        if user.idToken == nil { user = try await user.refreshTokensIfNeeded() }
        return try googleCredential(from: user)
    }

    private func googleCredential(from user: GIDGoogleUser) throws -> AuthCredential {
        guard let idToken = user.idToken?.tokenString else { throw MacAuthError.invalidGoogleToken }
        return GoogleAuthProvider.credential(
            withIDToken: idToken, accessToken: user.accessToken.tokenString)
    }
}
