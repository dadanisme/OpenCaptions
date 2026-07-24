//
//  MacFocusedValues.swift
//  OpenCaptions
//
//  Bridges view-local actions to the scene-level `Commands` (menu bar). Menu
//  commands live at the App/Scene level, but every action here is owned by a
//  local view (`TranscriptionsScreen`, `MacLiveTranscriptionView`,
//  `MacSessionDetailView`). The frontmost view publishes its actions via
//  `.focusedSceneValue(...)`; `OpenCaptionsCommands` reads them via `@FocusedValue`.
//  A `nil` value means "no such context is frontmost", which the menu items
//  turn into a disabled state automatically.
//

import SwiftUI

/// Actions the live recording screen exposes to the menu bar. Rebuilt whenever
/// `isPaused` changes so the Pause/Resume menu label stays in sync.
struct LiveRecordingActions {
    let isPaused: Bool
    let togglePause: () -> Void
    /// Ends & saves; routes through the view's confirm flow (`handleEnd`).
    let end: () -> Void
}

/// Show/hide the floating captions overlay. Rebuilt whenever visibility changes
/// so the Show/Hide Captions menu label stays in sync.
struct CaptionsOverlayActions {
    let isVisible: Bool
    let toggle: () -> Void
}

// MARK: - Focused value keys

private struct StartRecordingKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct LiveRecordingKey: FocusedValueKey {
    typealias Value = LiveRecordingActions
}

private struct ExportSummaryKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ImportMediaKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct CaptionsOverlayKey: FocusedValueKey {
    typealias Value = CaptionsOverlayActions
}

// MARK: - FocusedValues accessors

extension FocusedValues {
    /// Begin a new recording (published by the session list when not recording).
    var startRecording: (() -> Void)? {
        get { self[StartRecordingKey.self] }
        set { self[StartRecordingKey.self] = newValue }
    }

    /// Pause/resume + end for the active live recording screen.
    var liveRecording: LiveRecordingActions? {
        get { self[LiveRecordingKey.self] }
        set { self[LiveRecordingKey.self] = newValue }
    }

    /// Export the frontmost saved session's summary as a PDF.
    var exportSummary: (() -> Void)? {
        get { self[ExportSummaryKey.self] }
        set { self[ExportSummaryKey.self] = newValue }
    }

    /// Open the media-file importer (published by the session list when the
    /// `fileImport` flag is on). Nil elsewhere → the menu item disables.
    var importMedia: (() -> Void)? {
        get { self[ImportMediaKey.self] }
        set { self[ImportMediaKey.self] = newValue }
    }

    /// Show/hide the captions overlay for the active live recording.
    var captionsOverlay: CaptionsOverlayActions? {
        get { self[CaptionsOverlayKey.self] }
        set { self[CaptionsOverlayKey.self] = newValue }
    }
}
