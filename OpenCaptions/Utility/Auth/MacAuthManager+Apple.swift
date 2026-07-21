//
//  MacAuthManager+Apple.swift
//  OpenCaptions
//
//  Sign in with Apple → Firebase. The credential is delivered by SwiftUI's
//  `SignInWithAppleButton` (see `MacSignInControls`), so there is no ASAuthorization
//  controller/delegate or presentation-anchor plumbing to port — the biggest
//  difference from the iOS AuthManager, which drives the controller manually.
//  The token→Firebase exchange and the nonce helpers are copied ~verbatim.
//

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import Foundation

extension MacAuthManager {

    /// Exchanges an Apple ID credential for a Firebase session, then persists the
    /// identity. `rawNonce` is the UNHASHED nonce whose SHA256 was set on the
    /// original request (Firebase re-hashes it to verify the token).
    func handleAppleCredential(
        _ credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async throws {
        // Cache the Apple user id for launch-time credential-state checks.
        UserDefaults.standard.set(credential.user, forKey: appleUserIDKey)

        // Apple only provides name/email on the very first authorization.
        if let fullName = credential.fullName {
            let name = PersonNameComponentsFormatter().string(from: fullName)
            if !name.isEmpty { saveUserName(name) }
        }
        if let email = credential.email, !email.isEmpty { saveUserEmail(email) }

        guard let tokenData = credential.identityToken,
              let tokenString = String(data: tokenData, encoding: .utf8) else {
            throw MacAuthError.invalidAppleToken
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: tokenString,
            rawNonce: rawNonce,
            fullName: credential.fullName
        )

        let result = try await Auth.auth().signIn(with: firebaseCredential)
        let user = result.user

        // Push the display name onto the Firebase profile if we have one.
        if let displayName = userName, !displayName.isEmpty {
            let change = user.createProfileChangeRequest()
            change.displayName = displayName
            try? await change.commitChanges()
        }
        // Firebase persists the email from Apple's token on first sign-in; read it
        // back so we always have it locally on later logins when Apple omits it.
        if let firebaseEmail = user.email, !firebaseEmail.isEmpty {
            saveUserEmail(firebaseEmail)
        }

        saveUserID(user.uid)
    }

    // MARK: - Nonce (ported verbatim from iOS AuthManager+AccountDeletion)

    static func randomNonceString(length: Int = 32) throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "MacAuthManager",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to generate secure random bytes"]
            )
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { byte in charset[Int(byte) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        let hashedData = SHA256.hash(data: Data(input.utf8))
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}
