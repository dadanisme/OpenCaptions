# macOS transcript auto-scroll fix (issue #239)

**Date:** 2026-07-09
**Scope:** `OgmoMac` target — captions overlay (primary) + main live view (secondary).
**Status:** implemented — imperative `scrollTo` to the newest real line.
`.defaultScrollAnchor(.bottom)` was tried first and **rejected** (it hung the app on
a flush); see below.

## Problem

The macOS **captions overlay** (`CaptionsOverlayView`, hosted in a borderless
`NSPanel` via `NSHostingView`) auto-scroll misbehaved: scrolling up then back down
could leave it blank, it occasionally blanked for no reason, and it sometimes
snapped the wrong direction instead of following new text down. It was most
visible on the overlay because the strip is short — any offset error fills the
whole visible area. The main live view shared the same fragility but its tall
window masked it.

### Root cause

Both surfaces pinned to the bottom with a **manual `proxy.scrollTo("bottom")`**
fired synchronously inside `.onChange`, over a `LazyVStack`, targeting a
zero-height trailing anchor `Color.clear.frame(height: 1).id("bottom")`. Four
compounding issues:

1. **LazyVStack + 1px trailing anchor is unreliable.** A lazy stack only realizes
   rows near the viewport; the 1-point anchor below the fold is often not
   materialized, so `scrollTo("bottom")` has no realized target and silently
   no-ops or lands on stale geometry.
2. **Flush removes rows from the top.** Every ~70 lines, `extractOldLines()` does
   `removeFirst(20)` on the arrays feeding the `ForEach`, shifting the scrolled
   offset with no compensation. A flush left `totalLineCount` **unchanged**
   (`flushedLineCount` +20, `textLines` −20, net 0), so
   `.onChange(of: totalLineCount)` did **not** re-pin afterward — the strip stayed
   jumped until the next partial update happened to fire the other `.onChange`.
3. **Scroll ran before layout settled.** `scrollTo` inside `.onChange` executes in
   the same update pass, computing the offset against pre-mutation geometry.
4. **Short surface + `NSHostingView` host.** The overlay is a small strip, so any
   offset error blanks the whole visible area, and the borderless-panel host has
   less predictable scroll/layout timing than an in-scene `ScrollView`.

## Rejected: `.defaultScrollAnchor(.bottom)`

The first attempt replaced the manual pinning with the native
**`.defaultScrollAnchor(.bottom)`** modifier (macOS 14.0+) — the fix the issue
suggested. On paper it maintains the bottom edge from real content geometry as the
content both grows and shrinks. **In practice it froze the app.** On macOS,
`.defaultScrollAnchor(.bottom)` over a `LazyVStack` whose rows are **removed from
the top** (our flush) drives an unrecoverable layout-invalidation loop: the strip
pinned fine at first, then hung on the first flush — a full hang the user could not
even force-quit. So the modifier is unusable for this list; it is **not** used
anywhere in the fix.

## Fix

Keep an imperative `ScrollViewReader` + `proxy.scrollTo(…)`, but fix the three
things the old code got wrong (this is the fallback the issue anticipated):

- **Target a real, realized view** — the live partial (`id("partial")`) when
  present, else the **last committed line's id** — never the zero-height
  `Color.clear` anchor a `LazyVStack` may not have materialized (kills cause #1).
- **Re-pin after a flush** by observing `finalLines.ids.count` instead of
  `totalLineCount`: a flush drops `ids.count` by 20 (and a new line raises it by 1),
  so the `.onChange` actually fires — the old `totalLineCount` was net-zero across a
  flush and never re-pinned (kills cause #2). Streaming growth is still caught by
  `.onChange(of: partialLine)`; `.onAppear` handles the initial jump.
- The scroll is a single imperative call, so there is no `.defaultScrollAnchor`
  layout loop and no hang (kills the freeze). This mirrors the proven
  `ScrollViewReader` + `scrollTo(realID)` pattern already used in
  `MacSessionDetailView+Playback.swift`.

Both views share a small private helper:

```swift
private func scrollToNewest(_ proxy: ScrollViewProxy) {
    if !viewModel.partialLine.isEmpty {
        proxy.scrollTo("partial", anchor: .bottom)
    } else if let lastID = viewModel.finalLines.ids.last {
        proxy.scrollTo(lastID, anchor: .bottom)
    }
}
```

The per-row `.id(id)` and `.id("partial")` anchors (removed in the rejected
attempt) are **restored** — `scrollTo` needs them as targets.

Removed the now-orphaned `TranscriberModel.totalLineCount` (it was only ever
written; its sole reader was the deleted `.onChange`, and the fix observes
`ids.count` instead).

### Behavior notes

- **Short-content position is natural (top-aligned).** Unlike
  `.defaultScrollAnchor(.bottom)`, `scrollTo(lastID, anchor: .bottom)` is a no-op
  while the content fits the viewport, so early in a session lines start at the top
  and only begin tracking the bottom once they overflow — the original behavior, no
  bottom-hug.
- **Safe-area inset.** The main live view hosts the transport pill via
  `.safeAreaInset(edge: .bottom)`; `anchor: .bottom` settles the newest line within
  the reduced safe region, i.e. just above the pill.
- **Append race.** The scroll is fired without a runloop defer (matching the proven
  playback pattern). A brand-new bubble that is not yet laid out when `scrollTo`
  fires self-corrects on the next `partialLine`/`ids.count` change. If residual
  jitter ever shows, wrap the `scrollTo` in a one-tick `DispatchQueue.main.async`.

## iOS is intentionally out of scope

The iOS live transcript (`unmute/Views/TranscriptView/TranscriptionContainer.swift`
+ `ScrollStateObserver.swift`) is affected by a **related but distinct** set of
causes and — unlike macOS — deliberately supports a **scroll-away / "jump to live"**
UX (a `UIScrollView` KVO observer distinguishes user drag from content shifts).
Applying `.defaultScrollAnchor(.bottom)` there would fight a user scrolling up to
read history, so the iOS path needs a tailored fix (dynamic `Range<Int>` ForEach,
`sortedLines` refresh timing vs. synchronous `flushedLineCount` bumps, the
leading-edge throttle, and the KVO animated-scroll race). Tracked separately.
