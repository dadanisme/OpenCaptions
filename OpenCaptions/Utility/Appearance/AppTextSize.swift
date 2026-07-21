//
//  AppTextSize.swift
//  OgmoMac
//
//  App-WIDE font-size scaling for the general macOS UI (sidebar, session list,
//  session detail + summary, settings, sign-in) — INDEPENDENT of the transcript /
//  captions size (`TranscriptTextSize` + `LiveSessionStore.transcriptTextSizeKey`).
//  See docs/2026-07-10-macos-app-wide-font-size.md (issue #270).
//
//  Same mechanism as the transcript: macOS ignores Dynamic Type for built-in text
//  styles, so we scale the ACTUAL point size (via `Font.scaled`). The persisted
//  multiplier lives under `LiveSessionStore.appTextSizeKey`; it reuses
//  `TranscriptTextSize.range` / `.step` / `.defaultMultiplier` for the slider, but
//  writes a DIFFERENT key so the two sizes never affect each other.
//
//  Coverage is broad: `.appTextScaling()` at each window/scene root both injects
//  the multiplier into the environment (`\.appTextScale`, read by `.appScaledFont`)
//  AND sets a scaled DEFAULT font, so unstyled/system text (default button labels,
//  list rows, empty states) scales too. Text that sets an explicit style opts in
//  with `.appScaledFont(_:)` (a plain `.font(.headline)` would otherwise override
//  the scaled default and stay a fixed size). At multiplier 1.0 everything resolves
//  to the platform's own point sizes, so the default appearance is unchanged.
//

import SwiftUI

// MARK: - Slider stops

/// Discrete multiplier stops for the app-wide UI size. Fine 10% increments through
/// 150% for everyday tuning, then coarse **200% / 300%** jumps for large-text
/// accessibility. The jumps are non-uniform, so the Settings slider runs on the
/// stop INDEX (a uniform-`step` slider can't express 150→200→300) — see
/// `MacSettingsView`. The default (100%) is `TranscriptTextSize.defaultMultiplier`,
/// shared so both sizes reset to the same baseline.
enum AppTextSize {
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 2.0, 3.0]

    /// The stop index closest to `value`, so a stored multiplier maps onto a slider
    /// notch (and a legacy out-of-set value lands on its nearest stop).
    static func index(for value: Double) -> Int {
        steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
    }
}

// MARK: - Environment

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue = TranscriptTextSize.defaultMultiplier
}

extension EnvironmentValues {
    /// The live app-wide text-size multiplier, injected by `.appTextScaling()`.
    /// Defaults to `1.0` so a subtree without a scaling root (e.g. a standalone
    /// SwiftUI preview) renders at normal size.
    var appTextScale: Double {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

// MARK: - Root injector

/// Reads the persisted app-wide multiplier and pushes it down the subtree: both as
/// `\.appTextScale` (for `.appScaledFont`) and as a scaled DEFAULT font (so
/// unstyled/system text scales too). `@AppStorage` makes it reactive, so moving the
/// Settings slider re-renders every scaling root — across windows — live. Apply once
/// per window / scene root.
private struct AppTextScalingRoot: ViewModifier {
    @AppStorage(LiveSessionStore.appTextSizeKey) private var multiplier = TranscriptTextSize.defaultMultiplier

    func body(content: Content) -> some View {
        content
            .environment(\.appTextScale, multiplier)
            .font(.scaled(.body, multiplier: multiplier))
    }
}

extension View {
    /// Installs app-wide font scaling for this subtree. See `AppTextScalingRoot`.
    func appTextScaling() -> some View { modifier(AppTextScalingRoot()) }
}

// MARK: - Per-site scaled font

/// Applies a semantic text style scaled by the ambient `\.appTextScale`.
private struct AppScaledFont: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let style: Font.TextStyle
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.scaled(style, multiplier: scale, design: design))
    }
}

extension View {
    /// Drop-in replacement for `.font(style)` on general-UI text that sets an
    /// explicit style, so it scales with the app-wide setting. Unstyled text does
    /// not need this — it already inherits the scaled default font from
    /// `.appTextScaling()`. Pass `design: .monospaced` where the original used
    /// `.font(.<style>.monospaced())`.
    func appScaledFont(_ style: Font.TextStyle, design: Font.Design = .default) -> some View {
        modifier(AppScaledFont(style: style, design: design))
    }
}
