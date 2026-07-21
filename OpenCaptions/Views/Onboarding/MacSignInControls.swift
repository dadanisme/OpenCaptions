//
//  MacSignInControls.swift
//  OgmoMac
//
//  The reusable sign-in control stack: Continue with Google (primary), Sign in
//  with Apple, an "or" divider, and a Firebase email/password form. Extracted from
//  the old standalone SignInView so both the onboarding Sign-in step and the
//  guest-upgrade sheet (Settings → Account) share one implementation.
//
//  Owns its own working/error state — `MacAuthManager` tracks neither — and reports
//  the signed-in transition to its parent by observing `auth.isSignedIn`.
//

import AppKit
import AuthenticationServices
import SwiftUI

struct MacSignInControls: View {
    @Environment(MacAuthManager.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// The unhashed nonce for the in-flight Apple request; its SHA256 goes on the
    /// request and the raw value completes the Firebase exchange.
    @State private var currentNonce = ""

    private var canSubmit: Bool {
        !isWorking && email.contains("@") && password.count >= 6
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                googleButton
                
                SignInWithAppleButton(.signIn) { request in
                    let nonce = (try? MacAuthManager.randomNonceString()) ?? ""
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = MacAuthManager.sha256(nonce)
                } onCompletion: { result in
                    handleAppleCompletion(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .frame(maxWidth: 320)
                .disabled(isWorking)
            }

            orDivider
            emailForm

            if let errorMessage {
                Text(errorMessage)
                    .appScaledFont(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 320)
                    .multilineTextAlignment(.center)
            }

            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    /// Compact bordered button carrying the real multicolor Google logo asset.
    private var googleButton: some View {
        Button(action: handleGoogleSignIn) {
            HStack(spacing: 10) {
                Image("GoogleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text("Continue with Google")
                    .appScaledFont(.callout)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .frame(maxWidth: 320)
        .disabled(isWorking)
    }

    private var orDivider: some View {
        HStack {
            VStack { Divider() }
            Text("or").appScaledFont(.caption).foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .frame(maxWidth: 320)
    }

    private var emailForm: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled(true)
                SecureField("Password (6+ characters)", text: $password)
                    .textContentType(.password)
                    .onSubmit { if canSubmit { submit(create: false) } }
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Sign In") { submit(create: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                Button("Create Account") { submit(create: true) }
                    .disabled(!canSubmit)
            }
        }
        .frame(maxWidth: 320)
    }

    // MARK: - Actions

    private func handleGoogleSignIn() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            errorMessage = "Couldn't find a window to present sign-in."
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await auth.signInWithGoogle(presenting: window)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Unexpected Apple credential."
                return
            }
            let nonce = currentNonce
            isWorking = true
            errorMessage = nil
            Task {
                do {
                    try await auth.handleAppleCredential(credential, rawNonce: nonce)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isWorking = false
            }
        case .failure(let error):
            // A user cancel isn't worth surfacing as an error.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        }
    }

    private func submit(create: Bool) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                if create {
                    try await auth.createAccount(email: trimmedEmail, password: password)
                } else {
                    try await auth.signIn(email: trimmedEmail, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
