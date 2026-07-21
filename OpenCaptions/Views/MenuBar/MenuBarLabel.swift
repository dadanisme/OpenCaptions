//
//  MenuBarLabel.swift
//  OgmoMac
//
//  The system menu-bar item's icon: the rounded Ogmo logo with a small badge
//  signalling recording state (red dot while recording, orange pause bars while
//  paused, nothing when idle).
//
//  A `.resizable()` SwiftUI image in a MenuBarExtra label is NOT clamped by
//  `.frame` — the full-resolution asset renders huge. So the icon is composited
//  into a fixed-size `NSImage` and shown via `Image(nsImage:)`, which the status
//  item renders at its natural (18pt) size.
//

import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let status: MenuBarState.Status

    var body: some View {
        Image(nsImage: MenuBarIcon.render(status: status))
    }
}

/// Draws the menu-bar icon (logo + state badge) into a fixed-size NSImage.
enum MenuBarIcon {
    /// Menu-bar icons are a fixed ~18pt (they don't scale with Dynamic Type).
    private static let side: CGFloat = 18

    static func render(status: MenuBarState.Status) -> NSImage {
        let base = NSImage(named: "opencaptions-logo")
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            base?.draw(in: rect)
            drawBadge(for: status, in: rect)
            return true
        }
        image.isTemplate = false // keep the logo in full colour
        return image
    }

    /// A corner badge: a coloured dot (with a white ring for contrast), plus two
    /// white bars for the paused state.
    private static func drawBadge(for status: MenuBarState.Status, in rect: NSRect) {
        guard status != .idle else { return }
        let d = side * 0.45
        let dot = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)

        NSColor.white.setFill()
        NSBezierPath(ovalIn: dot).fill()
        (status == .paused ? NSColor.systemOrange : NSColor.systemRed).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: 1.2, dy: 1.2)).fill()

        guard status == .paused else { return }
        NSColor.white.setFill()
        let barW = d * 0.14, barH = d * 0.42, gap = d * 0.14
        let y = dot.midY - barH / 2
        NSBezierPath(rect: NSRect(x: dot.midX - gap / 2 - barW, y: y, width: barW, height: barH)).fill()
        NSBezierPath(rect: NSRect(x: dot.midX + gap / 2, y: y, width: barW, height: barH)).fill()
    }
}
