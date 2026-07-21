//
//  MacAuthManager+Google.swift
//  OpenCaptions
//
//  Sign in with Google → Firebase. Uses the GoogleSignIn SDK's macOS flow
//  (`signIn(withPresenting: NSWindow)`, backed by ASWebAuthenticationSession) to
//  obtain a Google ID token, then exchanges it for a Firebase session via
//  `GoogleAuthProvider`. The OAuth client id is read from the app's Firebase
//  options (GoogleService-Info.plist CLIENT_ID), so nothing is hardcoded here.
//
//  Added as the primary sign-in on macOS because Sign in with Apple's Firebase
//  audience validation rejects a developer's custom bundle id; Google has no such
//  per-bundle-id audience constraint. Both flows are surfaced by
//  `MacSignInControls` (onboarding + the guest-upgrade sheet).
//

import AppKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn

extension MacAuthManager {

    /// Runs the Google sign-in flow in `window`, exchanges the result for a
    /// Firebase session, and persists the identity (mirrors the Apple/email tails).
    func signInWithGoogle(presenting window: NSWindow) async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw MacAuthError.missingGoogleClientID
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
        guard let idToken = result.user.idToken?.tokenString else {
            throw MacAuthError.invalidGoogleToken
        }
        let accessToken = result.user.accessToken.tokenString

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: accessToken
        )
        let authResult = try await Auth.auth().signIn(with: credential)
        let user = authResult.user

        if let displayName = user.displayName, !displayName.isEmpty {
            saveUserName(displayName)
        }
        if let email = user.email, !email.isEmpty {
            saveUserEmail(email)
        }
        saveUserID(user.uid)
    }
}
