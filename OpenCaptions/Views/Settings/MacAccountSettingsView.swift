//
//  MacAccountSettingsView.swift
//  OgmoMac
//
//  The Settings → Account pane. Two states:
//  • Signed in — edit the display name, and Sign Out.
//  • Offline guest — an explainer plus "Sign In to Sync", which signs into a real
//    account, marks it onboarded (so the gate keeps them in the app), and migrates
//    their local-guest sessions into the account. Extracted from MacSettingsView to
//    keep both files focused. See docs/2026-07-11-macos-onboarding.md.
//

import AppKit
import SwiftUI

struct MacAccountSettingsView: View {
    @Environment(MacAuthManager.self) private var auth

    /// Editable copy of the display name; committed only when the Firebase profile
    /// update succeeds.
    @State private var nameDraft = ""
    @State private var isSavingName = false
    @State private var nameError: String?
    /// Presents the guest → account upgrade sign-in sheet.
    @State private var showUpgrade = false
    /// Presents the confirmation-gated account-deletion sheet.
    @State private var showDeleteAccount = false
    /// Marketing-communications consent, loaded from and mirrored to the Firestore
    /// user doc. Opt-in: defaults off and only flips on an explicit user toggle (#251).
    @State private var marketingOptIn = false
    /// The Settings window, captured while it's key (before the sheet opens) so it can
    /// be closed after deletion — see the Delete Account button.
    @State private var settingsWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            if auth.isGuest {
                guestPane
            } else {
                signedInPane
            }
            #if DEBUG
            debugSection
            #endif
        }
    }

    // MARK: - Offline guest

    private var guestPane: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .appScaledFont(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("You're using Ogmo offline")
                    .appScaledFont(.title3)
                    .fontWeight(.semibold)
                Text("Your transcriptions are stored privately on this Mac. Sign in to sync them across your devices and unlock cloud transcription with speaker labels.")
                    .appScaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { showUpgrade = true } label: {
                Text("Sign In to Sync")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 400)
        .sheet(isPresented: $showUpgrade) { upgradeSheet }
    }

    private var upgradeSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Sign in to Ogmo")
                    .appScaledFont(.title2)
                    .fontWeight(.semibold)
                Text("Your offline transcriptions move into your account and start syncing.")
                    .appScaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            MacSignInControls()
            Button("Not Now") { showUpgrade = false }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 420)
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { finishUpgrade() }
        }
    }

    /// Signing in cleared guest mode and (via the sign-in mirror) reset the gate to
    /// this account's onboarding flag — which a fresh account hasn't set. Mark it
    /// complete so the gate keeps the user in the app, then move their local-guest
    /// sessions into the account.
    private func finishUpgrade() {
        guard let uid = auth.userID else { return }
        auth.completeOnboarding(guest: false)
        if let container = LiveSessionStore.shared.modelContainer {
            Task { await SessionOwnerBackfill.claimGuestSessions(container: container, userId: uid) }
        }
        showUpgrade = false
    }

    // MARK: - Signed in

    private var signedInPane: some View {
        VStack {
            Form {
                Section("Signed in as") {
                    LabeledContent("Name") {
                        TextField("Your name", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .disabled(isSavingName)
                            .onSubmit(saveName)
                            .labelsHidden()
                    }
                    // The name feeds both recognition and the mention alert, so a
                    // short calling name works better than a full legal name (#255).
                    Text("Use the name people actually call you — Ogmo listens for it and alerts you when it's spoken during a recording.")
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Email", value: auth.userEmail ?? "—")
                    if let nameError {
                        Text(nameError)
                            .appScaledFont(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button(action: saveName) {
                            if isSavingName {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Save Name")
                            }
                        }
                        .disabled(!canSaveName)
                    }
                }

                Section("Communications") {
                    // Custom binding so the setter fires ONLY on user interaction —
                    // the `.task` load below assigns `marketingOptIn` directly and must
                    // not trigger a redundant write-back of the value just read.
                    Toggle("Email me product news and updates", isOn: Binding(
                        get: { marketingOptIn },
                        set: { newValue in
                            marketingOptIn = newValue
                            FirestoreSyncService.shared.syncMarketingOptIn(newValue)
                        }
                    ))
                    Text("Occasional emails about new features and improvements. You can turn this off anytime.")
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .task(id: auth.userName) { nameDraft = auth.userName ?? "" }
            .task { marketingOptIn = await FirestoreSyncService.shared.fetchMarketingOptIn() }

            Button(role: .destructive) {
                auth.signOut()
                // Signing out swaps the main window back to onboarding; close this
                // Settings window too so it doesn't linger over the signed-out app.
                NSApp.keyWindow?.close()
            } label: {
                Text("Sign Out")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal)

            // Deliberately quieter than Sign Out — deletion is rare and the sheet
            // itself gates it. Apple requires an in-app deletion path (5.1.1(v)).
            Button(role: .destructive) {
                // Capture the Settings window now, while it's key and no sheet is up.
                // After deletion we close THIS window; reading NSApp.keyWindow from
                // inside the just-dismissed sheet would target the sheet (or the main
                // window) instead.
                settingsWindow = NSApp.keyWindow
                showDeleteAccount = true
            } label: {
                Text("Delete Account")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal)
            // Also require the container the sheet needs, so an enabled button can never
            // open an empty sheet (the container is set at launch, so this is defensive).
            .disabled(auth.isDeleting || LiveSessionStore.shared.modelContainer == nil)
        }
        .padding(.vertical)
        .sheet(isPresented: $showDeleteAccount) {
            if let container = LiveSessionStore.shared.modelContainer {
                // Deletion succeeded — the main window is already back on onboarding;
                // close the captured Settings window too (mirrors Sign Out).
                MacDeleteAccountSheet(modelContainer: container) { settingsWindow?.close() }
            }
        }
    }

    /// Save is available only for a non-empty name that differs from the current one.
    private var canSaveName: Bool {
        guard !isSavingName else { return false }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (auth.userName ?? "")
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveName else { return }
        nameError = nil
        isSavingName = true
        Task {
            do {
                try await auth.updateDisplayName(trimmed)
                nameDraft = trimmed
            } catch {
                nameError = error.localizedDescription
            }
            isSavingName = false
        }
    }

    // MARK: - Debug

    #if DEBUG
    /// Developer affordance to replay onboarding. Essential for a guest, who has no
    /// Sign Out to trigger the DEBUG onboarding reset. Sign-out in DEBUG already
    /// wipes onboarding (see MacAuthManager.signOut).
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Debug")
                .appScaledFont(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
            Button("Reset Onboarding", role: .destructive) { resetOnboarding() }
                .controlSize(.small)
            Text("Wipes onboarding state (and signs out) so the setup assistant runs again.")
                .appScaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 16)
    }

    private func resetOnboarding() {
        if auth.isSignedIn {
            auth.signOut()              // DEBUG sign-out also wipes onboarding
        } else {
            auth.resetOnboardingState() // guest: clear onboarding + guest flag
        }
        // Close Settings so the main window's restored onboarding is visible.
        NSApp.keyWindow?.close()
    }
    #endif
}
