//
//  MenuBarState.swift
//  OgmoMac
//
//  App-level state powering the system menu-bar item (`MenuBarExtra` in
//  `OgmoMacApp`). The menu-bar item is a SEPARATE scene that must work while
//  the main window is in the background, so — unlike the main menu commands,
//  which read `@FocusedValue` from the focused window (see `OgmoCommands`) —
//  it can't rely on focused values. The recording screens push their status +
//  action closures here; `MenuBarContent` reads them. Mirrors the shared
//  `@Observable @MainActor` singleton pattern of `MacAuthManager`.
//

import Foundation

/// The main window's scene id, shared by `OgmoMacApp`'s `Window` scene and the
/// menu-bar item's `openWindow(id:)` calls.
enum MainWindowID {
    static let main = "main"
}

@Observable
@MainActor
final class MenuBarState {
    static let shared = MenuBarState()
    private init() {}

    enum Status {
        case idle, recording, paused
    }

    /// Current recording state, mirrored from the live screen's view model.
    var status: Status = .idle

    // Action closures registered by the frontmost recording context. Nil means
    // the action is unavailable, which the menu items turn into a disabled row.

    /// Begin a new recording. Set by the list screen while it's on screen and
    /// idle; nil otherwise (e.g. the window is closed) — in which case the
    /// menu-bar item opens the window and sets `pendingStartRequest` instead.
    var startRecording: (() -> Void)?
    /// Set by the menu-bar "New Recording" when there's no live `startRecording`
    /// (window closed). The list screen consumes it on appear to auto-start.
    var pendingStartRequest = false
    /// Pause/resume the live session. Nil when not recording.
    var togglePause: (() -> Void)?
    /// End & save the live session (routes through the on-screen confirm). Nil
    /// when not recording.
    var endAndSave: (() -> Void)?
    /// Show/hide the floating captions overlay. Nil when not recording.
    var toggleCaptions: (() -> Void)?
    /// Whether the captions overlay is currently shown (drives the menu label).
    var captionsVisible = false
}
