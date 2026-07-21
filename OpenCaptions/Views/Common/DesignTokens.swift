//
//  DesignTokens.swift
//  OgmoMac
//
//  Design-system color tokens for the native macOS app. Unlike the iOS target's
//  fixed light-mode palette, macOS follows the system appearance (no forced mode),
//  so tokens here are appearance-adaptive.
//

import AppKit
import SwiftUI

// MARK: - Design System Colors

extension Color {
    enum DS {
        /// Background tint for a sentence that ends in a question mark, so questions
        /// stand out at a glance (macOS analogue of iOS `Color.DS.questionHighlight`).
        ///
        /// A translucent tint of the OS **emphasized-selection color** (a saturated
        /// tint of the user's accent). It sits between the gentle system highlight
        /// color and the full-strength selection: bold enough to read, soft enough
        /// that the row's normal text — left INHERITED (dark in Light, light in Dark),
        /// never forced white — stays legible on top. Follows the accent and adapts
        /// to light/dark, with a touch more alpha in Dark where a tint over a dark row
        /// reads weaker.
        static let questionHighlight = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.selectedContentBackgroundColor.withAlphaComponent(isDark ? 0.45 : 0.32)
        })
    }
}
