//
//  CaptionsOverlayView.swift
//  OpenCaptions
//
//  Caption strip rendered inside the floating overlay panel
//  (`CaptionsOverlayController`). Shows the live transcript — all in-memory lines
//  plus the hot partial — in a scroll view auto-pinned to the bottom, so the
//  newest text is always visible and older lines roll off the top as they scroll
//  out (and out of memory once flushed to storage). It reads the SAME
//  `MacTranscriptionViewModel` the main window uses — Observation keeps it live
//  even though it's hosted in an `NSHostingView` rather than a SwiftUI scene.
//  Colors match the main transcript via `SpeakerPalette`.
//

import SwiftUI

struct CaptionsOverlayView: View {
    /// The active session's view model, passed by reference from the store.
    let viewModel: MacTranscriptionViewModel
    /// Background opacity for the material fallback (macOS < 26); ignored on the
    /// Liquid Glass path. Bound to the same key the Settings slider writes.
    @AppStorage(LiveSessionStore.captionsOpacityKey) private var backgroundOpacity = 0.9
    /// Shared transcript font-size multiplier. Read directly via `@AppStorage`
    /// (not the environment) so it crosses the overlay's `NSHostingView` boundary,
    /// which injects no environment — same approach as `backgroundOpacity`.
    @AppStorage(LiveSessionStore.transcriptTextSizeKey) private var textSizeMultiplier = 1.0

    private let corner: CGFloat = 16

    /// Auto-scroll gate. Starts pinned; a `MacScrollStateObserver` flips it
    /// off when the user scrolls up in the strip to read earlier captions and back
    /// on when they return to the bottom.
    @State private var shouldAutoScroll = true

    /// The signed-in user's name for the `@Name` mention highlight. Read from the
    /// shared auth manager rather than `@Environment`: this view is hosted in an
    /// `NSHostingView` that injects no environment (same reason the font/opacity
    /// keys above are read via `@AppStorage`). Observation still tracks the change.
    private var userName: String? { MacAuthManager.shared.userName }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if isEmpty {
                        Text("Listening…")
                            .font(.transcript(.body, multiplier: textSizeMultiplier))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.finalLines.ids.enumerated()), id: \.element) { index, id in
                            line(at: index).id(id)
                        }
                        // Only when the partial can't continue the last caption —
                        // nothing committed yet, or a new speaker. Otherwise it
                        // renders at that caption's tail (see `line(at:)`).
                        if let partial = viewModel.standalonePartial {
                            // `cached: false` — streaming partial stays out of the
                            // shared segment cache so it can't evict committed lines.
                            HighlightedMessageText(partial, userName: userName, cached: false)
                                .font(.transcript(.body, multiplier: textSizeMultiplier))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("partial")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                // Detects user-driven scroll and drives `shouldAutoScroll` so tokens
                // stop yanking the strip to the newest caption while the user reads
                // earlier text; resumes once they scroll back to the bottom.
                // A tighter threshold than the main view: this panel is only ~160pt
                // tall, so 50pt would swallow ~3 lines of scroll-up before pausing.
                .background(
                    MacScrollStateObserver(shouldAutoScroll: $shouldAutoScroll, bottomThreshold: 24)
                        .frame(width: 0, height: 0)
                )
            }
            // Pin to the newest content with an imperative scroll to a REAL realized
            // view — the live partial if present, else the last committed line — never
            // a zero-height anchor a LazyVStack may not have materialized. Fires on
            // finalLines.revision (every committed token, INCLUDING one that only grows
            // the last caption in place), on ids.count (a top flush changes it, so a
            // flush re-pins — the old net-zero totalLineCount signal missed that), and
            // on partialLine (streaming) — but ONLY while pinned to the bottom, so a
            // caption arriving while the user reads earlier text leaves their position
            // alone. We deliberately do NOT use `.defaultScrollAnchor(.bottom)`: it
            // hangs the app when the flush removes rows from the LazyVStack.
            .onChange(of: viewModel.finalLines.revision) { _, _ in
                if shouldAutoScroll { scrollToNewest(proxy) }
            }
            .onChange(of: viewModel.finalLines.ids.count) { _, _ in
                if shouldAutoScroll { scrollToNewest(proxy) }
            }
            .onChange(of: viewModel.partialLine) { _, _ in
                if shouldAutoScroll { scrollToNewest(proxy) }
            }
            // User scrolled back to the bottom — snap the last sliver and resume.
            .onChange(of: shouldAutoScroll) { _, resumed in
                if resumed { scrollToNewest(proxy) }
            }
            .onAppear { scrollToNewest(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CaptionsBackground(corner: corner, opacity: backgroundOpacity))
        // A subtle hairline so the strip reads as a distinct surface over busy
        // backgrounds (video, slides) regardless of the material's blur.
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        // A grip hint in the bottom-right corner so users discover the panel is
        // resizable. Decorative only — the actual resize is handled by the
        // borderless panel's `.resizable` edge regions, so let events pass through.
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    /// True until the first token lands (no committed lines and no partial).
    private var isEmpty: Bool {
        viewModel.finalLines.ids.isEmpty && viewModel.partialLine.isEmpty
    }

    /// Scrolls the newest content to the bottom: the live partial if present, else
    /// the last committed line. Targets a real, realized row — never a zero-height
    /// anchor — so the short strip pins reliably (and re-pins after a top flush).
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        // The partial only has its own row when it can't continue the last caption;
        // otherwise it grows inside that caption, which is the row to pin.
        if viewModel.standalonePartial != nil {
            proxy.scrollTo("partial", anchor: .bottom)
        } else if let lastID = viewModel.finalLines.ids.last {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func line(at index: Int) -> some View {
        // Guard against a flush racing the render (arrays shrink together, but a
        // stale index could still slip through between reads).
        if index < viewModel.finalLines.textLines.count {
            let speaker = index < viewModel.finalLines.speakers.count
                ? viewModel.finalLines.speakers[index] : -1
            VStack(alignment: .leading, spacing: 2) {
                if speaker > 0, index < viewModel.finalLines.name.count {
                    HStack(spacing: 4) {
                        // App glyph for system-audio lines; nothing for mic lines.
                        SourceAppIcon(bundleID: index < viewModel.finalLines.sourceApps.count
                            ? viewModel.finalLines.sourceApps[index] : nil,
                            sizeMultiplier: textSizeMultiplier)
                        Text(viewModel.finalLines.name[index])
                            .font(.transcript(.caption, multiplier: textSizeMultiplier))
                            .fontWeight(.semibold)
                            .foregroundStyle(SpeakerPalette.color(for: speaker))
                    }
                }
                // The newest caption carries the engine's in-flight text at its
                // tail (dimmed, same paragraph) so a partial reads as this caption
                // continuing rather than a separate one appearing below.
                captionText(at: index)
                    .font(.transcript(.body, multiplier: textSizeMultiplier))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A caption's text, with the live partial concatenated onto the LAST one as a
    /// dimmed tail. `Text + Text` keeps both in one paragraph; a sibling view would
    /// wrap to a new line. Only the ephemeral tail is uncached — the committed part
    /// keeps its `@Name` highlight and its cache entry.
    private func captionText(at index: Int) -> Text {
        let committed = HighlightedMessageText(
            viewModel.finalLines.textLines[index], userName: userName).asText
        guard index == viewModel.finalLines.ids.count - 1,
              let partial = viewModel.trailingPartial else { return committed }
        return committed + Text(partial).foregroundStyle(.secondary)
    }
}

/// Classic corner resize grip (three diagonal ticks) drawn in the bottom-right,
/// hinting that the overlay panel can be dragged larger.
private struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            for offset in stride(from: CGFloat(2), through: size.width, by: 4) {
                var path = Path()
                path.move(to: CGPoint(x: size.width - offset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - offset))
                context.stroke(path, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
            }
        }
        .frame(width: 11, height: 11)
    }
}

/// Overlay background: Liquid Glass on macOS 26+, a configurable-opacity material
/// blur otherwise (translucency the user tunes in Settings for older systems).
private struct CaptionsBackground: ViewModifier {
    let corner: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner)
        if #available(macOS 26.0, *) {
            // Requires the macOS 26 (Xcode 26) SDK. Glass manages its own
            // translucency, so the opacity setting doesn't apply here.
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial).opacity(opacity))
                .clipShape(shape)
        }
    }
}
