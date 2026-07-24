//
//  MacShareSessionSheet.swift
//  OpenCaptions
//
//  Share dialog for a session (live or saved): the public link with a Copy
//  button, plus password controls (set / change / remove). Operates purely on
//  the cloud session id — the caller mints it (via `shareLive()` or
//  `SessionLinkSharer.share`) before presenting, so the backing Firestore docs
//  already exist. See docs/2026-07-06-macos-firestore-share.md.
//

import AppKit
import SwiftUI

/// Identifies the session being shared for `.sheet(item:)` presentation.
struct ShareTarget: Identifiable {
    let id: String
}

struct MacShareSessionSheet: View {
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @State private var hasPassword = false
    @State private var isLoadingPassword = true
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var linkCopied = false
    @FocusState private var passwordFocused: Bool

    /// Base URL of the web session viewer, supplied per-deployment via the
    /// git-ignored Config.xcconfig (SESSION_SHARE_BASE_URL, no trailing slash).
    private var shareURL: String {
        let base = Bundle.main.infoDictionary?["SESSION_SHARE_BASE_URL"] as? String ?? ""
        return "\(base)/\(sessionId)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            linkSection
            Divider()
            passwordSection
            if let errorMessage {
                Text(errorMessage).appScaledFont(.caption).foregroundStyle(.red)
            }
            footer
        }
        .padding(24)
        .frame(width: 440)
        .task { await loadPasswordState() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Share Session").appScaledFont(.headline)
            Text("Anyone with the link can view this transcription in a browser.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Public link").appScaledFont(.subheadline).fontWeight(.medium)
            HStack(spacing: 8) {
                Text(shareURL)
                    .appScaledFont(.callout)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button(linkCopied ? "Copied" : "Copy", action: copyLink)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Password protection").appScaledFont(.subheadline).fontWeight(.medium)
            if isLoadingPassword {
                ProgressView().controlSize(.small)
            } else if hasPassword {
                HStack {
                    Label("This session is password protected.", systemImage: "lock.fill")
                        .appScaledFont(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await removePassword() } }
                        .disabled(isSubmitting)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Set a password (\(SessionPasswordService.passwordLengthRange.lowerBound)–\(SessionPasswordService.passwordLengthRange.upperBound) chars)", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($passwordFocused)
                        .onSubmit { Task { await setPassword() } }
                    Button("Set") { Task { await setPassword() } }
                        .disabled(!isLengthValid || isSubmitting)
                        .fixedSize()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - State

    private var isLengthValid: Bool {
        SessionPasswordService.passwordLengthRange.contains(password.count)
    }

    private func loadPasswordState() async {
        hasPassword = await FirestoreSyncService.shared.fetchHasPassword(cloudSessionId: sessionId) ?? false
        isLoadingPassword = false
    }

    // MARK: - Actions

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareURL, forType: .string)
        withAnimation { linkCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation { linkCopied = false }
        }
    }

    private func setPassword() async {
        guard isLengthValid, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await SessionPasswordService.shared.setPassword(sessionId: sessionId, password: password)
            password = ""
            hasPassword = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSubmitting = false
    }

    private func removePassword() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await SessionPasswordService.shared.removePassword(sessionId: sessionId)
            hasPassword = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSubmitting = false
    }
}
