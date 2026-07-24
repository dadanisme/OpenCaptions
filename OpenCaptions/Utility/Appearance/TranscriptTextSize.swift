//
//  TranscriptTextSize.swift
//  OpenCaptions
//
//  Shared font-size scaling for the live transcript + captions overlay.
//  The size is a persisted Double MULTIPLIER (see `LiveSessionStore.transcriptTextSizeKey`).
//
//  macOS does NOT honor Dynamic Type for built-in text styles, so
//  `.dynamicTypeSize(...)` has no visible effect here.
//  Instead we scale the ACTUAL point size: `Font.transcript(_:multiplier:)` reads
//  the platform's point size for a semantic text style (`NSFont.preferredFont` —
//  not a hardcoded literal, so each role keeps its system-defined relative size)
//  and multiplies it. At multiplier 1.0 the result is pixel-identical to
//  `.font(style)`, so there is no change to the current appearance at the default.
//
//  Three surfaces read/write the same key so a change reflects everywhere live:
//  a fine-grained slider (60%–300%) in the transport pill and in Settings, and a
//  discrete percentage `Picker` in the native menu-bar item (which can't host a
//  slider). `menuSteps` backs that picker; `nearestStep(to:)` reflects a
//  slider-set value onto the closest step so the menu checkmark stays sensible.
//

import AppKit
import SwiftUI

/// Continuous slider bounds shared by the pill and Settings sliders (60%–300%),
/// plus the discrete percentage steps the native menu-bar `Picker` uses (it can't
/// host a slider).
enum TranscriptTextSize {
    static let range: ClosedRange<Double> = 0.6...3.0
    static let step: Double = 0.1
    static let defaultMultiplier: Double = 1.0

    /// Discrete multipliers for the menu-bar picker, labeled as percentages. The
    /// slider stays fine-grained across `range`; these are just quick anchors.
    static let menuSteps: [Double] = [0.6, 0.8, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    /// The menu step closest to `value`, so a slider-set value still lands on a
    /// sensible checkmark in the discrete picker. Returns an exact `menuSteps`
    /// element (never a recomputed value), so it always matches a picker tag.
    static func nearestStep(to value: Double) -> Double {
        menuSteps.min { abs($0 - value) < abs($1 - value) } ?? defaultMultiplier
    }

    /// "150%"-style label for a multiplier.
    static func percentLabel(_ multiplier: Double) -> String {
        "\(Int((multiplier * 100).rounded()))%"
    }
}

// MARK: - Scaled semantic font

extension Font {
    /// A semantic text style scaled by an arbitrary point-size `multiplier`, with an
    /// optional font `design`. See the file header for why macOS needs explicit
    /// point-size scaling instead of `.dynamicTypeSize(...)`. At `multiplier == 1.0`
    /// and the default design this equals `.font(style)`.
    ///
    /// Shared by BOTH the transcript sizing (`Font.transcript`, below) and the
    /// app-wide UI sizing (`AppTextSize.swift`), which drive it from independent
    /// multipliers stored under different keys.
    ///
    /// Carries the style's WEIGHT through the rescale (not just its point size) —
    /// otherwise `.headline`, which is semibold at the SAME 13pt as regular `.body`,
    /// would collapse into a plain body font. Any later `.fontWeight(_:)` view
    /// modifier still overrides this base weight, as it did with `.font(style)`.
    static func scaled(_ style: Font.TextStyle, multiplier: Double, design: Font.Design = .default) -> Font {
        let base = NSFont.preferredFont(forTextStyle: style.nsTextStyle)
        return .system(size: base.pointSize * CGFloat(multiplier), weight: base.swiftUIWeight, design: design)
    }

    /// A semantic text style scaled by the transcript multiplier. Thin alias over
    /// `scaled(_:multiplier:)` so the live transcript / captions read the same math.
    static func transcript(_ style: Font.TextStyle, multiplier: Double) -> Font {
        scaled(style, multiplier: multiplier)
    }
}

private extension NSFont {
    /// The SwiftUI `Font.Weight` closest to this font's descriptor weight trait, so
    /// a rebuilt `.system(size:weight:)` keeps the semantic style's weight (e.g.
    /// `.headline` stays semibold). Falls back to `.regular` when no weight trait is
    /// present (the case for `.body`/`.caption`/etc.), matching the prior behavior.
    /// Thresholds are the midpoints between the standard `NSFont.Weight` raw values.
    var swiftUIWeight: Font.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let raw = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        switch raw {
        case ..<(-0.7): return .ultraLight
        case ..<(-0.5): return .thin
        case ..<(-0.2): return .light
        case ..<0.115:  return .regular
        case ..<0.265:  return .medium
        case ..<0.35:   return .semibold
        case ..<0.48:   return .bold
        case ..<0.59:   return .heavy
        default:        return .black
        }
    }
}

private extension Font.TextStyle {
    /// The AppKit text style whose platform point size backs `Font.transcript`.
    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle:  return .largeTitle
        case .title:       return .title1
        case .title2:      return .title2
        case .title3:      return .title3
        case .headline:    return .headline
        case .subheadline: return .subheadline
        case .body:        return .body
        case .callout:     return .callout
        case .footnote:    return .footnote
        case .caption:     return .caption1
        case .caption2:    return .caption2
        @unknown default:  return .body
        }
    }
}
