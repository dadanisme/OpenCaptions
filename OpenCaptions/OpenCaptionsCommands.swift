//
//  OpenCaptionsCommands.swift
//  OpenCaptions
//
//  The app's menu-bar commands. A single "Session" menu carries
//  every transcription action; each item reads a `@FocusedValue` published by
//  the relevant screen and disables itself when that context isn't frontmost.
//  The standard App/Edit/View/Window/Help menus come from SwiftUI for free, so
//  they're not re-declared here — except Settings (Cmd+,): SwiftUI only
//  generates that item automatically for a `Settings { }` scene, which this
//  app no longer has (Settings is a `NavSection` destination instead), so its
//  `.appSettings` placement is filled in below off the `openSettings` focused
//  value `ContentView` publishes.
//
//  Strings are hardcoded English — macOS UI localization is deferred (see
//  CLAUDE.md); there is no `LanguageManager` in this target yet.
//

import SwiftUI

struct OpenCaptionsCommands: Commands {
    @FocusedValue(\.startRecording) private var startRecording
    @FocusedValue(\.liveRecording) private var liveRecording
    @FocusedValue(\.exportSummary) private var exportSummary
    @FocusedValue(\.captionsOverlay) private var captionsOverlay
    @FocusedValue(\.importMedia) private var importMedia
    @FocusedValue(\.openSettings) private var openSettings
    @FocusedValue(\.findInTranscript) private var findInTranscript

    var body: some Commands {
        // Drop the default WindowGroup "New Window" command so its Cmd+N doesn't
        // collide with "New Session" below.
        CommandGroup(replacing: .newItem) {}

        // App ▸ Settings… (Cmd+,) — normally free from a `Settings { }` scene;
        // this app fills the placement itself since it has none. `openSettings`
        // is nil while the main window is closed (there's no `ContentView` to
        // publish it) — a state this app explicitly supports via `MenuBarExtra`
        // — so the fallback reopens the window and stashes `.settings` for
        // `ContentView` to pick up once it appears, rather than disabling.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if let openSettings {
                    openSettings()
                } else {
                    LiveSessionStore.shared.pendingSection = .settings
                    LiveSessionStore.shared.openMainWindow?()
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // File ▸ Import Audio or Video… (published by the session list; nil while a
        // recording is active, so the item disables then).
        CommandGroup(replacing: .importExport) {
            Button("Import Audio or Video…") { importMedia?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importMedia == nil)
        }

        // Edit ▸ Find in Transcript (Cmd+F) — published by `MacSessionDetailView`
        // only while its Transcript tab is frontmost; nil (item disabled) on the
        // Summary tab or anywhere else.
        CommandGroup(after: .textEditing) {
            Button("Find in Transcript") { findInTranscript?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(findInTranscript == nil)
        }

        CommandMenu("Session") {
            Button("New Session") { startRecording?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(startRecording == nil)

            Button(liveRecording?.isPaused == true ? "Resume" : "Pause") {
                liveRecording?.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(liveRecording == nil)

            Button("End & Save") { liveRecording?.end() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(liveRecording == nil)

            Button(captionsOverlay?.isVisible == true ? "Hide Captions" : "Show Captions") {
                captionsOverlay?.toggle()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(captionsOverlay == nil)

            Divider()

            Button("Export PDF…") { exportSummary?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportSummary == nil)
        }
    }
}
