//
//  MacHUDOverlayController.swift
//  OpenCaptions
//
//  Owns the transient HUD badge shown when a global hotkey fires:
//  a borderless, non-activating, always-on-top `NSPanel` that fades in near the
//  bottom-center of the main screen, holds briefly, and fades out — like the
//  system volume HUD. It must appear over WHATEVER app is frontmost without
//  stealing focus, so it uses the same panel traits as the captions overlay plus
//  `ignoresMouseEvents` (it's purely informational and never a click target).
//
//  Modeled on `CaptionsOverlayController`. App Store safe: window level +
//  collection behavior + drawing our own overlay need no entitlement or private
//  API.
//

import AppKit
import SwiftUI

@MainActor
final class MacHUDOverlayController {
    private var panel: NSPanel?
    /// Bumped on every `show`; the pending auto-dismiss only fires if it still
    /// matches, so a rapid second hotkey replaces the badge instead of letting
    /// the first press's timer hide the second's.
    private var generation = 0

    /// How long the badge stays fully visible before fading out.
    private let holdMilliseconds: UInt64 = 1_100

    /// Shows the hotkey-confirmation badge for `outcome`.
    func show(_ outcome: HotKeyOutcome) {
        present(MacHUDOverlayView(outcome: outcome))
    }

    /// Shows a free-form badge (icon + one line) — e.g. the name-mention cue.
    func show(symbol: String, message: String, isNeutral: Bool = false) {
        present(MacHUDOverlayView(symbol: symbol, message: message, isNeutral: isNeutral))
    }

    /// Presents `view` in the badge panel, (re)creating the panel on first use.
    private func present(_ view: MacHUDOverlayView) {
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: view)
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        generation &+= 1
        let mine = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(self?.holdMilliseconds ?? 1_100)))
            guard let self, self.generation == mine else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        guard let panel else { return }
        // Re-check generation in the completion too: a new `show()` during this
        // 0.3s fade reuses the same panel and bumps `generation`, so without this
        // guard the older press's fade-out would order the newer badge off screen.
        let mine = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, self.generation == mine else { return }
            panel?.orderOut(nil)
        })
    }

    /// Centers horizontally on the main screen, ~18% up from the bottom of the
    /// visible frame (clear of the Dock, mirrors the system HUD's placement).
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.18
        )
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 184, height: 152),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // Rides over every Space and full-screen apps; never enters window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Never take focus from the frontmost app.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Purely informational — clicks pass straight through to the app below.
        panel.ignoresMouseEvents = true
        return panel
    }
}
