# macOS Onboarding Clipping Fix (Open Captions)

**Date:** 2026-07-16 · **Target:** `OpenCaptions`

## Summary

On the macOS onboarding flow (`MacOnboardingView`) the step-indicator dots (top)
and the primary action button (bottom, "Get Started" / "Continue" / "Start
Transcribing") were **clipped at the default window size** — the user had to
manually drag the window taller before they appeared, which is a hard blocker
since the button can't be pressed until it's revealed.

## Root cause

The main scene (`OpenCaptionsApp.swift`) is a single `Window` with **no
`.windowResizability`**, so it defaulted to `.automatic`. `.automatic` does **not**
enforce the content's minimum size on the AppKit window — the window can open (or
restore a persisted frame) **shorter** than the content needs. `MacOnboardingView`
declared `.frame(minHeight: 600)`; when the window is shorter than 600pt that frame
still reports its 600pt height and **overflow-centers** inside the shorter window,
so the fixed top (`MacOnboardingStepIndicator`) and bottom (`actionBar`) chrome
fall off **both** edges symmetrically while the middle step content stays visible.

Verified via SwiftUI layout algebra: min-frames only **floor**, never cap, so the
outer `.frame(minHeight: 400)` (OpenCaptionsApp) does not hide the inner 600 — the
content min compounds to `max(600, 400) = 600` during onboarding.

## Fix (two parts)

1. **Window sizing** — `OpenCaptionsApp.swift`: add `.windowResizability(.contentMinSize)`
   to the `Window` scene. The window now **floors at** the current content's minimum
   and **opens at** its content-fit ideal, so it can no longer open/restore shorter
   than the onboarding content. `.contentMinSize` (not `.contentSize`) sets **only**
   the floor — the window still resizes larger freely and the main `ContentView`
   (NavigationSplitView) window is unaffected apart from gaining a sensible ~400
   floor it lacked under `.automatic`. Scoped to the main scene only; `Settings`,
   `MenuBarExtra`, and the AppKit `NSPanel` overlays (captions/HUD) are untouched.

2. **Layout resilience** — `MacOnboardingView.swift`: **pin** the step indicator and
   action bar outside a `ScrollView`, and wrap **only** the middle `stepContent` in
   `ScrollView(.vertical)` with `.scrollBounceBehavior(.basedOnSize)`. The content is
   **centered when it fits** (`GeometryReader` → `.frame(minHeight: geo.size.height,
   alignment: .center)`) and **scrolls when it doesn't**. This guarantees the chrome
   stays visible even in cases `.contentMinSize` alone can't cover — a window macOS
   **clamps below content-min** because it can't exceed the screen: a large app-text
   size (`.appTextScaling()` goes up to 3×) or a short external display.

### Threshold change: `minHeight: 600` → `minHeight: 400, idealHeight: 600`

Critical interaction: if the hard `minHeight: 600` had stayed, the whole VStack
(pinned chrome + ScrollView) would still be 600pt tall inside a screen-clamped
short window and overflow-center — clipping the pinned chrome anyway, leaving the
ScrollView inert. So the hard min is **relaxed** to `idealHeight: 600` (the window
still **opens at 600**, where every step — the cloud Sign-in step is the tallest —
fits comfortably) plus a modest `minHeight: 400` floor (enough for the pinned
chrome + a scrollable middle). `idealHeight` wins on a nil proposal, so the greedy
`GeometryReader`'s tiny intrinsic ideal does not affect the 600 open size.

## Why the ScrollView is safe now

A prior comment deliberately avoided a ScrollView because it "flashed its scroller
and re-laid the AppKit-backed sign-in controls during the step change" — but that
was caused by a **crossfade** that briefly mounted two viewport-tall step frames.
`advance()` now swaps **instantly** (`step = next`), so only one step is ever live;
`.scrollBounceBehavior(.basedOnSize)` also means no bounce/scroller while content
fits (at the default 600 window the ScrollView is inert). Only the inert middle
scrolls — never the pinned chrome.

## Verification

Design and concrete diff were adversarially verified by independent reviewers
(SwiftUI window-sizing semantics, layout resilience, regression surface, and a
final concrete-diff review) — unanimous, no defects. The app is **not** built from
CLI here (developer builds in Xcode); a physical smoke test should confirm: (a) a
fresh onboarding window opens at 600 with dots + button visible; (b) the Sign-in
step fits at 600 at default text size; (c) shrinking the window scrolls the middle
while chrome stays pinned; (d) no one-frame scroller flash when stepping.

## Files

- `OpenCaptions/OpenCaptionsApp.swift` — `.windowResizability(.contentMinSize)` on the `Window` scene.
- `OpenCaptions/Views/Onboarding/MacOnboardingView.swift` — pinned chrome + scrolling middle; `minHeight: 400, idealHeight: 600`.

See also `docs/2026-07-11-macos-onboarding.md` (the onboarding flow itself).
