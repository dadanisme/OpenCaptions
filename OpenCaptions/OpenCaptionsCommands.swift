//
//  OpenCaptionsCommands.swift
//  OpenCaptions
//
//  The app's menu-bar commands (issue #173). A single "Recording" menu carries
//  every transcription action; each item reads a `@FocusedValue` published by
//  the relevant screen and disables itself when that context isn't frontmost.
//  Settings (Cmd+,) and the standard App/Edit/View/Window/Help menus come from
//  SwiftUI for free, so they're not re-declared here.
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

    var body: some Commands {
        // Drop the default WindowGroup "New Window" command so its Cmd+N doesn't
        // collide with "New Recording" below.
        CommandGroup(replacing: .newItem) {}

        // File ▸ Import Audio or Video… (published only when the fileImport flag is on,
        // so the item disables otherwise). Issue #302.
        CommandGroup(replacing: .importExport) {
            Button("Import Audio or Video…") { importMedia?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importMedia == nil)
        }

        CommandMenu("Recording") {
            Button("New Recording") { startRecording?() }
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
