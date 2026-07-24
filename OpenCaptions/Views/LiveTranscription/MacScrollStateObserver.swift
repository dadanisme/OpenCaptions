//
//  MacScrollStateObserver.swift
//  OpenCaptions
//
//  AppKit bridge that detects USER-driven scrolling in a SwiftUI ScrollView so the
//  live transcript and captions overlay can stop force-scrolling to the newest line
//  while the user is reading earlier text. Keys off `NSScrollView`'s
//  live-scroll notifications, which fire ONLY for user-initiated
//  scrolling (trackpad / wheel / scroller drag, incl. momentum) — a programmatic
//  `ScrollViewProxy.scrollTo` never posts them, so content-driven re-pins can never
//  be mistaken for the user scrolling away.
//

import AppKit
import SwiftUI

/// Zero-size probe dropped as a `.background` inside a SwiftUI `ScrollView`. It
/// resolves the enclosing `NSScrollView` once it's in the window and flips
/// `shouldAutoScroll` to match whether a user scroll left the viewport pinned near
/// the bottom: `false` when the user scrolls up to read, `true` again once they
/// scroll back down. The consuming view gates its scroll-to-newest on this flag.
struct MacScrollStateObserver: NSViewRepresentable {
    @Binding var shouldAutoScroll: Bool
    /// Distance (pt) from the bottom that still counts as "pinned".
    var bottomThreshold: CGFloat = 50

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.parent = self
        // Cheap idempotent retry: no-ops once attached, but recovers if the scroll
        // view wasn't resolvable at the first `viewDidMoveToWindow`.
        context.coordinator.attach(from: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Custom NSView that attaches to the enclosing scroll view once it lands in a window.
    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            coordinator?.attach(from: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacScrollStateObserver
        private weak var scrollView: NSScrollView?

        init(parent: MacScrollStateObserver) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Resolves the enclosing `NSScrollView` and subscribes to its live-scroll
        /// notifications. Idempotent — no-ops once attached or while the scroll view
        /// isn't in the hierarchy yet (a later call retries).
        func attach(from view: NSView) {
            guard scrollView == nil, let sv = view.enclosingScrollView else { return }
            scrollView = sv
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(scrollDidChange),
                name: NSScrollView.didLiveScrollNotification, object: sv
            )
            center.addObserver(
                self, selector: #selector(scrollDidChange),
                name: NSScrollView.didEndLiveScrollNotification, object: sv
            )
        }

        /// Fires for user-driven scroll only (live scroll + its end). Re-derives the
        /// pinned state from the live geometry and toggles `shouldAutoScroll`.
        @objc private func scrollDidChange(_ note: Notification) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let visible = sv.documentVisibleRect
            let docHeight = doc.frame.height
            // Content shorter than the viewport can't scroll — leave the flag as-is
            // (it defaults on, so an unscrollable transcript keeps auto-scrolling).
            guard docHeight > visible.height + 1 else { return }

            // SwiftUI's document view is flipped (y grows downward); branch on the
            // actual flip so the math is correct across SDK changes.
            let distanceFromBottom = doc.isFlipped
                ? docHeight - visible.maxY
                : visible.minY
            let isNearBottom = distanceFromBottom < parent.bottomThreshold

            if isNearBottom {
                if !parent.shouldAutoScroll { parent.shouldAutoScroll = true }
            } else if parent.shouldAutoScroll {
                parent.shouldAutoScroll = false
            }
        }
    }
}
