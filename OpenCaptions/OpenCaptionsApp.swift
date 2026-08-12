//
//  OpenCaptionsApp.swift
//  OpenCaptions
//
//  Standalone native macOS app entry point. Fully local-only: no accounts, no
//  cloud database. The transcription flow (record → transcript → save →
//  summarize) uses Soniox (or an on-device engine, Nemotron/Parakeet) + SwiftData +
//  OpenRouter for AI summaries. No Analytics.
//

import AppKit
import SwiftData
import SwiftUI

@main
struct OpenCaptionsApp: App {
    @State private var menuBar = MenuBarState.shared
    @State private var session = LiveSessionStore.shared

    /// Onboarding gate flag. `@AppStorage` so the gate re-evaluates the instant
    /// onboarding writes it.
    @AppStorage(LiveSessionStore.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false

    let sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: OpenCaptionsSchemaV2.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: OpenCaptionsMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            fatalError("Could not create ModelContainer (schema v1→v2 migration failed): \(error)")
        }
    }()

    init() {
        // One-time migration from the deleted binary Offline Mode key to the new
        // three-way transcription engine selection. Must run before `register`
        // below reads/sets defaults, so a migrated value is never mistaken for
        // "unset". See `LiveSessionStore+TranscriptionEngine.swift`.
        LiveSessionStore.migrateOfflineModeKeyIfNeeded()

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
            LiveSessionStore.transcriptionEngineKindKey: MacTranscriptionEngineKind.soniox.rawValue,
            LiveSessionStore.summaryProviderKindKey: SummaryProviderKind.openRouter.rawValue,
            LiveSessionStore.retranscriptionAutoKey: false,
            LiveSessionStore.speakerNamingAutoKey: true,
        ])
    }

    var body: some Scene {
        // A single `Window` (not `WindowGroup`) so the menu-bar item can reopen
        // or focus it via `openWindow(id:)` — a WindowGroup window, once closed,
        // can't be brought back by activating the app. `MainWindowID.main` is the
        // shared id both this scene and MenuBarContent use.
        Window("Open Captions", id: MainWindowID.main) {
            Group {
                // Every launch goes straight to the local library once onboarding
                // is done — there's no account to sign in or out of.
                if hasCompletedOnboarding {
                    ContentView()
                } else {
                    MacOnboardingView()
                }
            }
            .frame(minWidth: 480, minHeight: 400)
            // App-wide font scaling for the general UI (independent of the
            // transcript/captions size). Applied at the window root so the sidebar,
            // lists, detail, and pushed screens all inherit it. The live
            // transcript keeps its own explicit `Font.transcript(...)` sizing, and
            // the captions overlay is a separate window untouched by this.
            .appTextScaling()
            .environment(session)
            // Capture `openWindow` for non-view code (the global-hotkey Start
            // fallback raises the mic-permission UI even when the window is closed).
            .background(WindowOpenerBridge())
            .task {
                // Hand the store the shared container so the menu-bar item can
                // start a recording without an on-screen view supplying one.
                LiveSessionStore.shared.modelContainer = sharedModelContainer
                // Register the system-wide transcription hotkeys.
                // Idempotent, so this re-running on window recreation is a no-op.
                HotKeyManager.shared.start()
                // This task RE-RUNS whenever the window is (re)created, so the
                // launch-time backfills below are guarded on `!isActive` — skip
                // them while a session is live so reopening the window
                // mid-recording doesn't disturb it.
                if !LiveSessionStore.shared.isActive {
                    // Remove recorded-audio files left orphaned by a crash. Guarded
                    // by the not-active check so an in-flight recording's file is
                    // never swept.
                    await SessionAudioOrphanSweep.run(container: sharedModelContainer)
                    // Recompute the cached list-card fields for any session that
                    // predates one of them (durationMs/previewText/speakerNamesSummary).
                    await DerivedFieldsBackfill.run(container: sharedModelContainer)
                }
                // Mirror any session that has never been exported to markdown. On
                // the first launch after the feature shipped that is the whole
                // library (the one-time backfill); afterwards it is an empty fetch
                // that also self-heals an export interrupted by a quit or crash.
                // Safe alongside a live session — it only touches saved rows.
                await SessionExportCoordinator.backfillMissing(container: sharedModelContainer)
            }
        }
        .modelContainer(sharedModelContainer)
        .commands { OpenCaptionsCommands() }
        // Floor the window at its content's minimum size and open it at the
        // content-fit ideal. Under the default `.automatic`, the window could open
        // or restore SHORTER than the content min and clip the onboarding's fixed
        // top/bottom chrome. `.contentMinSize` sets only the floor — the
        // window still resizes larger freely (`.contentSize` would also cap the max
        // and lock the resizable main app). Per-scene: the MenuBarExtra scene below
        // is untouched. There is no `Settings { }` scene any more — Settings is a
        // `NavSection` destination inside this window (see `ContentView`), reached
        // via the sidebar's `SidebarSettingsFooter` or Cmd+, (wired in
        // `OpenCaptionsCommands` off the `openSettings` focused value).
        .windowResizability(.contentMinSize)

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
