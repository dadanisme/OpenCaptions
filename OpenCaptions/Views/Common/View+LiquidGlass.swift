//
//  View+LiquidGlass.swift
//  OpenCaptions
//
//  Shared Liquid Glass background for floating bars/controls. Prefer this over a
//  raw `.background(.regularMaterial…)` so surfaces adopt Liquid Glass wherever
//  the OS supports it, with a consistent translucent-material fallback below it.
//

import SwiftUI

extension View {
    /// Backs a floating bar/control with Liquid Glass on macOS 26+, falling back to
    /// a translucent material + hairline stroke + shadow on macOS 14–15 (below the
    /// `glassEffect` API). Pass the surface's clip shape (e.g. `Capsule()` or a
    /// `RoundedRectangle`).
    @ViewBuilder
    func liquidGlassBackground<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}
