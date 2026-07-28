//
//  FlowLayout.swift
//  OpenCaptions
//
//  Left-to-right wrapping layout: lays subviews out in a row and starts a new line
//  when the next one won't fit. Used by the Vocabulary screen for its term chips.
//
//  A `Layout` rather than a `LazyVGrid` because chips have naturally different widths
//  — a grid would force them into uniform columns and leave ragged gaps after short
//  terms. Each subview is measured at its ideal size and placed at exactly that size.
//

import SwiftUI

struct FlowLayout: Layout {
    /// Horizontal gap between items on the same line.
    var spacing: CGFloat = 6
    /// Vertical gap between lines.
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // No width proposal (e.g. inside a horizontally-unbounded container) means
        // "as wide as you like", so everything lands on one line.
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0 && lineWidth + spacing + size.width > maxWidth {
                widestLine = max(widestLine, lineWidth)
                totalHeight += lineHeight + lineSpacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }

        widestLine = max(widestLine, lineWidth)
        totalHeight += lineHeight

        // Fill the offered width so the container doesn't shrink-wrap to the last
        // line; fall back to the measured width when nothing was offered.
        return CGSize(width: proposal.width ?? widestLine, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if x > bounds.minX {
                x += spacing
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
