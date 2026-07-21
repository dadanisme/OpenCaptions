//
//  MacAuthManager+Email.swift
//  OpenCaptions
//
//  First-class Firebase email/password sign-in, shipped as a real sign-in
//  option. No password reset / email verification yet (deferred).
//

import FirebaseAuth
import Foundation

extension MacAuthManager {

    /// Signs into an existing Firebase email/password account.
    func signIn(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        finalizeEmailSession(user: result.user, fallbackEmail: email)
    }

    /// Creates a new Firebase account, seeds the display name from the email
    /// local-part, and signs in.
    func createAccount(email: String, password: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let displayName = email.components(separatedBy: "@").first ?? "User"
        let change = result.user.createProfileChangeRequest()
        change.displayName = displayName
        try? await change.commitChanges()
        finalizeEmailSession(user: result.user, fallbackEmail: email)
    }

    /// Shared persistence for both email paths — mirrors the Apple flow's tail.
    private func finalizeEmailSession(user: User, fallbackEmail: String) {
        if let displayName = user.displayName, !displayName.isEmpty {
            saveUserName(displayName)
        } else if (userName ?? "").isEmpty {
            saveUserName(fallbackEmail.components(separatedBy: "@").first ?? "User")
        }

        let resolvedEmail = (user.email?.isEmpty == false ? user.email : nil) ?? fallbackEmail
        if !resolvedEmail.isEmpty { saveUserEmail(resolvedEmail) }

        saveUserID(user.uid)
    }
}
