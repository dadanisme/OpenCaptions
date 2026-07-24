//
//  SourceAppIcon.swift
//  OpenCaptions
//
//  The small source-app glyph shown at the head of a transcript line when the
//  audio came from a specific app (system-audio / mixed capture). Renders NOTHING
//  when there's no attributable app — so mic / own-voice lines keep their layout
//  and no empty slot is reserved (a leading icon therefore reads as "this line is
//  app audio"). Shared by the live view, the saved-session detail, and the
//  captions overlay. See docs/2026-07-07-macos-source-app-attribution.md.
//

import SwiftUI

struct SourceAppIcon: View {
    let bundleID: String?
    /// Transcript font-size multiplier so the glyph scales with the caption text
    /// it sits beside (macOS ignores Dynamic Type, so `@ScaledMetric` alone won't
    /// track the shared setting — see `TranscriptTextSize`). Defaults to `1.0` for
    /// callers that don't scale (e.g. the saved-session detail view).
    var sizeMultiplier: Double = 1.0
    /// Base glyph size, aligned with the caption-sized header text.
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 14

    private var scaledSize: CGFloat { size * CGFloat(sizeMultiplier) }

    var body: some View {
        if bundleID == SourceAppMarker.unknownSystemAudio {
            // System audio we detected but couldn't attribute to a named app
            // (Safari/WebKit, FaceTime, unresolvable helpers).
            Image(systemName: "speaker.wave.2.fill")
                .font(.transcript(.caption, multiplier: sizeMultiplier))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("System audio"))
        } else if let bundleID, let icon = AppIconResolver.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: scaledSize, height: scaledSize)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityLabel(Text(AppIconResolver.name(forBundleID: bundleID) ?? "Source app"))
        }
    }
}
