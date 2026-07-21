//
//  MacDeleteAccountSheet.swift
//  OgmoMac
//
//  Confirmation-gated account-deletion sheet (Settings → Account). Because deletion
//  is permanent, the destructive action stays disabled until the user types the exact
//  phrase "delete my account" AND their account email — for every provider. The reauth
//  control then adapts to how they signed in: a password field (email), a Sign in with
//  Apple button (Apple), or a plain button that drives the Google web flow. The heavy
//  lifting lives in MacAuthManager+AccountDeletion; this view only collects intent.
//

import AuthenticationServices
import FirebaseAuth
import SwiftData
import SwiftUI

struct MacDeleteAccountSheet: View {
    @Environment(MacAuthManager.self) private var auth
    @Environment(\.dismiss) private var dismiss

    let modelContainer: ModelContainer
    /// Invoked after a successful deletion so the parent can close the Settings window
    /// (the main window has already swapped back to onboarding via the app gate).
    var onDeleted: () -> Void

    @State private var confirmPhrase = ""
    @State private var confirmEmail = ""
    @State private var password = ""
    /// Unhashed nonce for the in-flight Apple request (SHA256 goes on the request; the
    /// raw value completes the Firebase reauth) — mirrors MacSignInControls.
    @State private var rawNonce = ""

    private let requiredPhrase = "delete my account"

    private var accountEmail: String {
        auth.userEmail ?? Auth.auth().currentUser?.email ?? ""
    }

    private var phraseMatches: Bool {
        confirmPhrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == requiredPhrase
    }

    private var emailMatches: Bool {
        !accountEmail.isEmpty &&
        confirmEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == accountEmail.lowercased()
    }

    private var gatesPass: Bool { phraseMatches && emailMatches }

    var body: some View {
        VStack(spacing: 18) {
            header
            gateFields
            Divider().frame(maxWidth: 320)
            actionControl

            if let error = auth.deletionError, !error.isEmpty {
                Text(error)
                    .appScaledFont(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if auth.isDeleting { ProgressView().controlSize(.small) }

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(auth.isDeleting)
        }
        .padding(28)
        .frame(width: 420)
        .onAppear { auth.deletionError = nil }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            // Deletion ends in signOut() → isSignedIn flips false. Dismiss and let the
            // parent close the Settings window.
            if !signedIn { dismiss(); onDeleted() }
        }
    }

    // MARK: - Warning

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .appScaledFont(.largeTitle)
                .foregroundStyle(.red)
            Text("Delete your account?")
                .appScaledFont(.title3)
                .fontWeight(.semibold)
            Text("This permanently deletes your Ogmo account. All transcripts, summaries, and recorded audio stored on this Mac will be erased. This can't be undone.")
                .appScaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Confirmation gates

    private var gateFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Type “\(requiredPhrase)” to confirm")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
                TextField(requiredPhrase, text: $confirmPhrase)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .disabled(auth.isDeleting)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Type your email to confirm")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
                TextField(accountEmail.isEmpty ? "you@example.com" : accountEmail, text: $confirmEmail)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .disabled(auth.isDeleting)
            }
        }
        .frame(maxWidth: 320)
    }

    // MARK: - Provider-specific reauth action

    @ViewBuilder
    private var actionControl: some View {
        switch auth.currentProviderKind {
        case .email: emailAction
        case .apple: appleAction
        case .google: googleAction
        case .unknown: unknownNote
        }
    }

    private var emailAction: some View {
        VStack(spacing: 10) {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .disabled(auth.isDeleting)
                .onSubmit { if gatesPass && !password.isEmpty { runDelete(.email(password: password)) } }
            deleteButton(enabled: gatesPass && !password.isEmpty) {
                runDelete(.email(password: password))
            }
        }
    }

    private var googleAction: some View {
        deleteButton(enabled: gatesPass) { runDelete(.google) }
    }

    private var appleAction: some View {
        VStack(spacing: 8) {
            Text("Confirm with Apple to permanently delete your account")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SignInWithAppleButton(.continue) { request in
                let nonce = (try? MacAuthManager.randomNonceString()) ?? ""
                rawNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = MacAuthManager.sha256(nonce)
            } onCompletion: { handleApple($0) }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 40)
            .frame(maxWidth: 320)
            .disabled(!gatesPass || auth.isDeleting)
        }
    }

    private var unknownNote: some View {
        Text("We couldn't determine your sign-in method. Please sign out and sign back in, then try again.")
            .appScaledFont(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
    }

    private func deleteButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text("Delete My Account")
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .frame(maxWidth: 320)
        .disabled(!enabled || auth.isDeleting)
    }

    // MARK: - Actions

    private func runDelete(_ reauth: MacDeletionReauth) {
        Task { await auth.deleteAccount(reauth: reauth, modelContainer: modelContainer) }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                auth.deletionError = "Unexpected Apple credential."
                return
            }
            runDelete(.apple(credential: credential, rawNonce: rawNonce))
        case .failure(let error):
            // A user cancel isn't worth surfacing as an error.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            auth.deletionError = error.localizedDescription
        }
    }
}
