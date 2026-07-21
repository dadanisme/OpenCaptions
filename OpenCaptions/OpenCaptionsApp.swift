//
//  OpenCaptionsApp.swift
//  OpenCaptions
//
//  Standalone native macOS app entry point. Uses Firebase Auth (Sign in with
//  Apple + email/password) to scope transcriptions per user; the transcription
//  flow itself (record → transcript → save → summarize) uses Soniox + SwiftData +
//  the summary cloud function. Firestore + Functions back the share-to-web feature
//  (live mirror, share link, password). RevenueCat meters cloud (Soniox) minutes
//  (see MacSubscriptionManager); no Analytics.
//

import AppKit
import FirebaseCore
import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct OpenCaptionsApp: App {
    @State private var auth = MacAuthManager.shared
    @State private var menuBar = MenuBarState.shared
    @State private var session = LiveSessionStore.shared
    @State private var subscriptions = MacSubscriptionManager.shared

    /// Onboarding gate flags (see MacAuthManager+Onboarding). `@AppStorage` so the
    /// gate re-evaluates the instant onboarding writes them — the offline path
    /// finishes without any observable auth change, so this is what flips the UI.
    @AppStorage(LiveSessionStore.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false
    @AppStorage(LiveSessionStore.guestModeKey) private var isGuestMode = false

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TranscriptionSession.self,
            TranscriptionLine.self,
            ActionItem.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Opt-in defaults for preferences the user hasn't set yet. Registering
        // (rather than only defaulting the @AppStorage) means `LiveSessionStore`'s
        // raw `UserDefaults` reads also see these before Settings is ever opened —
        // so the captions overlay auto-shows on the very first recording.
        UserDefaults.standard.register(defaults: [
            LiveSessionStore.captionsAutoShowKey: true,
            LiveSessionStore.captionsOpacityKey: 0.9,
            LiveSessionStore.transcriptTextSizeKey: TranscriptTextSize.defaultMultiplier,
            LiveSessionStore.appTextSizeKey: TranscriptTextSize.defaultMultiplier,
            LiveSessionStore.sessionAudioKey: true,
            LiveSessionStore.offlineModeKey: false,
            LiveSessionStore.retranscriptionAutoKey: false,
        ])
        FirebaseApp.configure()
        // Mirror the signed-in Firebase profile (name/email/photo) into the auth
        // cache. Registered here — right after configure — so the initial callback
        // fires before the UI reads identity. Fixes the Apple display name vanishing
        // on repeat logins (the credential omits it; Firebase persists it).
        // The listener also configures RevenueCat with the uid (see MacAuthManager).
        MacAuthManager.shared.startListening()
        // Re-fetch the minute balance whenever the app becomes active, so gating
        // never runs on a stale balance (mirrors iOS's foreground refresh). Guarded
        // against mid-session flushing inside refreshStatusOnForeground(). Registered
        // once here (App.init runs once); no-ops until RevenueCat is configured.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await MacSubscriptionManager.shared.refreshStatusOnForeground() }
        }
    }

    var body: some Scene {
        // A single `Window` (not `WindowGroup`) so the menu-bar item can reopen
        // or focus it via `openWindow(id:)` — a WindowGroup window, once closed,
        // can't be brought back by activating the app. `MainWindowID.main` is the
        // shared id both this scene and MenuBarContent use.
        Window("Open Captions", id: MainWindowID.main) {
            Group {
                // Show the main UI only once onboarding is done AND the user can
                // actually use the app: signed in (cloud) or a deliberate offline
                // guest. A signed-out / token-expired cloud user (onboarded but
                // neither signed in nor a guest) falls back to onboarding to
                // re-authenticate.
                if hasCompletedOnboarding && (auth.isSignedIn || isGuestMode) {
                    ContentView()
                } else {
                    MacOnboardingView()
                }
            }
            .frame(minWidth: 480, minHeight: 400)
            // App-wide font scaling for the general UI (independent of the
            // transcript/captions size). Applied at the window root so the sidebar,
            // lists, detail, sign-in, and pushed screens all inherit it. The live
            // transcript keeps its own explicit `Font.transcript(...)` sizing, and
            // the captions overlay is a separate window untouched by this. (#270)
            .appTextScaling()
            .environment(auth)
            .environment(session)
            .environment(subscriptions)
            // Capture `openWindow` for non-view code (the global-hotkey Start
            // fallback raises the mic-permission UI even when the window is closed).
            .background(WindowOpenerBridge())
            .task {
                // Hand the store the shared container so the menu-bar item can
                // start a recording without an on-screen view supplying one.
                LiveSessionStore.shared.modelContainer = sharedModelContainer
                // Register the system-wide transcription hotkeys (issue #249).
                // Idempotent, so this re-running on window recreation is a no-op.
                HotKeyManager.shared.start()
                // Start the remote feature-flag listener (gates share-to-web), then
                // reconcile any live/paused Firestore session docs left by a crash so
                // they don't stay stuck at `live` on the web. Reconcile needs the
                // signed-in uid, so it runs after the credential check.
                //
                // This task RE-RUNS whenever the window is (re)created. Skip reconcile
                // while a session is live so reopening the window mid-recording doesn't
                // seal the still-live share doc as `ended`.
                FeatureFlagService.shared.startListening()
                await auth.checkExistingCredential()
                if !LiveSessionStore.shared.isActive {
                    await FirestoreSyncService.shared.reconcileLiveSessions()
                    // Remove recorded-audio files left orphaned by a crash. Guarded
                    // by the not-active check so an in-flight recording's file is
                    // never swept.
                    await SessionAudioOrphanSweep.run(container: sharedModelContainer)
                }
            }
            .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
        .modelContainer(sharedModelContainer)
        .commands { OpenCaptionsCommands() }
        // Floor the window at its content's minimum size and open it at the
        // content-fit ideal. Under the default `.automatic`, the window could open
        // or restore SHORTER than the content min and clip the onboarding's fixed
        // top/bottom chrome (#312). `.contentMinSize` sets only the floor — the
        // window still resizes larger freely (`.contentSize` would also cap the max
        // and lock the resizable main app). Per-scene: the Settings and MenuBarExtra
        // scenes below are untouched.
        .windowResizability(.contentMinSize)

        // Advanced account actions live here (Cmd+,). Minimal today; scaffolded
        // for the deferred account-deletion / subscription panes.
        Settings {
            MacSettingsView()
                .environment(auth)
                .environment(subscriptions)
                // Scale the Settings window too, so its own General slider previews
                // the change live as it moves.
                .appTextScaling()
        }

        // System menu-bar item (top-right status area): recording status + full
        // transport, usable while the main window is in the background. Its icon
        // reflects idle / recording / paused. Note: because a MenuBarExtra keeps
        // the app alive, closing the window no longer quits Open Captions — use Quit Open Captions.
        MenuBarExtra {
            MenuBarContent()
                .environment(menuBar)
        } label: {
            MenuBarLabel(status: menuBar.status)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Invisible helper that captures the scene's `openWindow` action and stashes it
/// on `LiveSessionStore`. `@Environment(\.openWindow)` is only readable inside a
/// view, so this tiny background view is the bridge that lets non-view code (the
/// global-hotkey Start fallback) reopen the main window. The `OpenWindowAction`
/// stays valid for the app's lifetime, so calling it later — after the window has
/// closed — reopens it.
private struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                LiveSessionStore.shared.openMainWindow = { openWindow(id: MainWindowID.main) }
            }
    }
}
