# macOS: stop force-scrolling to the bottom while reading past transcript (#314)

## Problem

On macOS both the in-app live transcript (`MacLiveTranscriptionView`) and the
captions overlay (`CaptionsOverlayView`) called `scrollToNewest` **unconditionally**
on every incoming token (`onChange(of: finalLines.ids.count)` and
`onChange(of: partialLine)`). If a user scrolled up to reread earlier text, the next
token yanked them straight back to the bottom, making the live transcript unreadable
during recording. iOS already gates this via `shouldAutoScroll`.

## Solution

Port the iOS gating to macOS: auto-scroll to the newest line **only** while the user
is pinned to the bottom; when they scroll up, stop and leave their position; resume
once they scroll back to the bottom. **Behavior-only — no "Jump to live" button** was
added (the iOS button was intentionally left out for the macOS surfaces; the user
resumes by scrolling back down).

### `MacScrollStateObserver` (new)

`OgmoMac/Views/LiveTranscription/MacScrollStateObserver.swift` — an
`NSViewRepresentable` dropped as a zero-size `.background` inside each SwiftUI
`ScrollView`. It:

1. Resolves the enclosing `NSScrollView` via `enclosingScrollView` after
   `viewDidMoveToWindow` (with an idempotent retry from `updateNSView`).
2. Subscribes to `NSScrollView.didLiveScrollNotification` /
   `didEndLiveScrollNotification`.
3. On each, computes distance-from-bottom (`documentVisibleRect` vs
   `documentView.frame.height`) and flips a bound `shouldAutoScroll`: `false` past the
   threshold, `true` when near the bottom.

The two consuming views gate their `scrollToNewest` calls behind `shouldAutoScroll`
and add an `onChange(of: shouldAutoScroll)` that snaps to the newest line the moment
it flips back to `true`.

### Why live-scroll notifications, not KVO on the offset

iOS uses `UIScrollView.contentOffset` KVO and must distinguish user scroll from
content/programmatic scroll via `isDragging || isDecelerating`, plus a 0.5s
`dismissTime` guard so residual deceleration doesn't fight a programmatic
scroll-to-bottom.

macOS `NSScrollView` gives us a cleaner primitive: `didLiveScrollNotification` /
`didEndLiveScrollNotification` fire **only** for user-initiated scrolling (trackpad,
wheel, scroller drag, including momentum). A programmatic `ScrollViewProxy.scrollTo`
never posts them. So:

- Content-driven re-pins and the every-token `scrollToNewest` can never be mistaken
  for the user scrolling away — no `isDragging`-style gating needed.
- There is **no feedback loop** between the observer and the programmatic snap, so the
  iOS 0.5s deceleration guard is unnecessary on macOS and was deliberately omitted.

### Geometry

SwiftUI's macOS `ScrollView` is backed by an `NSScrollView` whose document view is
flipped (y grows downward). Distance-from-bottom is
`documentView.frame.height - documentVisibleRect.maxY`. The code branches on
`documentView.isFlipped` (falling back to `documentVisibleRect.minY` for a
non-flipped document) purely as cross-SDK insurance. When the content is shorter than
the viewport the observer returns without touching the flag, so an unscrollable
transcript keeps auto-scrolling.

### Thresholds

- Main live view: `bottomThreshold = 50` (default), matching iOS.
- Captions overlay: `bottomThreshold = 24`. The overlay panel is only ~160pt tall, so
  a 50pt threshold would swallow ~3 lines of scroll-up before pausing; 24pt (~1.5
  lines) makes the pause responsive on the small strip.

## Known limitation (pre-existing, out of scope)

The macOS live views render **only the in-memory hot window** (~50–70 speaker
bubbles); flushed lines are persisted to SwiftData and removed from `finalLines.ids`,
so they disappear from the live surfaces (unlike iOS, which reloads flushed lines on
scroll). Consequently:

- Scrollback during a live session is bounded to the hot window.
- When a flush fires (`removeFirst(20)`), the removed top rows shift the content even
  while the user is scrolled up. This gating change stops the **programmatic** yank to
  the bottom but cannot prevent the row-removal shift — that is inherent to the
  hot-window design and predates this change. Rendering flushed lines in the live view
  (à la iOS) would be a separate, larger feature.

## Verify on device

`didLiveScrollNotification` delivery inside the captions overlay's borderless
`.nonactivatingPanel` (`CaptionsOverlayController`) is the expected AppKit behavior
(scroll events route to the view under the cursor regardless of window key/active
state) but was not exercised in an automated build. Worth a quick manual check that
scrolling the captions strip while the main window is active pauses auto-scroll.

## Files

- `OgmoMac/Views/LiveTranscription/MacScrollStateObserver.swift` (new)
- `OgmoMac/Views/LiveTranscription/MacLiveTranscriptionView.swift`
- `OgmoMac/Views/LiveTranscription/CaptionsOverlayView.swift`
