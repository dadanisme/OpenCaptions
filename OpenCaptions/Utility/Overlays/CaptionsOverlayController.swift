//
//  CaptionsOverlayController.swift
//  OgmoMac
//
//  Owns the floating captions panel — a borderless, translucent, always-on-top
//  `NSPanel` that renders the live transcript over every other app (including
//  full-screen ones) so captions stay visible while the user watches a meeting,
//  video, or slides in another app.
//
//  It's driven imperatively (not a SwiftUI scene) for two reasons: the panel
//  needs AppKit-only traits SwiftUI's `Window` can't express on macOS 14
//  (non-activating, `.floating` level, join-all-Spaces), and it must be owned by
//  the app-level `LiveSessionStore` so it survives the main window closing.
//
//  App Store safe: window level + collection behavior + drawing our own overlay
//  need no entitlement and no private API (no screen-recording/accessibility
//  permission — we never read other apps' content).
//

import AppKit
import SwiftUI

@MainActor
final class CaptionsOverlayController {
    private var panel: NSPanel?

    /// Whether the overlay panel is currently on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the overlay for the given session, creating the panel on first use.
    /// Rebinds the hosted view to `viewModel` each time so a new session reuses
    /// the same (position-remembered) panel. The panel is a fixed-size band; the
    /// hosted view bottom-anchors its lines so the newest text is always visible.
    func show(viewModel: MacTranscriptionViewModel) {
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: CaptionsOverlayView(viewModel: viewModel))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Hides the overlay without destroying it, so its saved frame is preserved
    /// for the next session.
    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            // `.resizable` gives a borderless panel invisible edge/corner resize
            // regions so the user can grow it to show more caption history; the
            // interior stays draggable via `isMovableByWindowBackground`.
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 240, height: 80)
        // Above normal windows; joins every Space and rides over full-screen apps
        // so captions stay put no matter what the user switches to.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Never take focus from the frontmost app when clicked or shown.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // Draggable from anywhere on its translucent body.
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Persist position/size across sessions and launches.
        panel.setFrameAutosaveName("OgmoCaptionsOverlay")
        // First-run placement: top-right of the main screen, below the menu bar.
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            )
            panel.setFrameOrigin(origin)
        }
        return panel
    }
}
