# macOS: Floating Captions Overlay + Background-Persistent Live Session

**Date:** 2026-07-06
**Issue:** #201 (epic #103)
**Target:** OpenCaptions only (iOS untouched)

## Problem

On macOS the live transcript was only visible inside the Open Captions window. During a
meeting/lecture/call the user watches *another* app, so captions were invisible
without switching away. #201 asked for an always-on-top captions overlay.

While scoping it, a second, coupled requirement surfaced: **closing the main window
killed the running transcription.** The recording view model lived as `@State` inside
`MacLiveTranscriptionView`, so closing the window destroyed it, and the view's
`.onDisappear` called `discard()` — throwing the session away. An overlay that shows
captions over other apps is only useful if the session survives the window closing.
So the two were built together.

## Decision

### 1. App-level session ownership — `LiveSessionStore`

The active `MacTranscriptionViewModel` was hoisted out of the view into a new
`@Observable @MainActor` singleton, `LiveSessionStore.shared` (matching the existing
`MacAuthManager` / `MenuBarState` pattern — only `.shared` singletons survive a window
close on this single-`Window` app kept alive by its `MenuBarExtra`).

- `store.viewModel: MacTranscriptionViewModel?` is the **single source of truth for
  "a session is active"** (running, paused, or failed-with-kept-transcript). It
  replaced `TranscriptionsScreen`'s local `isRecording` flag. `TranscriptionsScreen`
  shows the live screen via `if let vm = store.viewModel`, so a reopened window
  **rebinds** to the running session instead of showing the list.
- `MacLiveTranscriptionView` takes the VM by injection (`let viewModel`) instead of
  owning it (`@State`). Its `.onDisappear` no longer discards — window teardown must
  not end the session.
- `startIfPermitted()` guards on `viewModel.hasStarted` (`serviceGeneration > 0`) so a
  reopened window **rebinds** rather than starting a second session over the running
  one. (`hasStarted` was added to the VM as the "has `start()` ever run" signal.)
- Menu-bar transport (`MenuBarState.togglePause/endAndSave/toggleCaptions`) is wired by
  the store, targeting the store — not the transient view — so Pause / End / Captions
  keep working from the status-bar item **with the window closed**.
- Menu-bar `status` is mirrored from the VM via a `withObservationTracking` re-arm loop
  (the iOS kill-switch pattern) so the label stays correct without an on-screen view.
- Reopen-time trap fixed: `OpenCaptionsApp`'s window `.task` re-runs
  `reconcileLiveSessions()` on every window (re)creation, which would seal a still-live
  Firestore share doc as `ended`. It's now gated on `!LiveSessionStore.shared.isActive`.

**Exit semantics:** ending a session (in-window End & Save, in-window back-confirm, or
menu-bar End & Save) stops the VM then calls `store.clearSession()`, which nils the VM
(list re-appears), hides the overlay, and clears the menu-bar transport. Window close
does **none** of this — the session keeps running.

### 2. Floating captions overlay

An **AppKit `NSPanel`** (`CaptionsOverlayController`), not a SwiftUI scene, because it
needs traits SwiftUI's `Window` can't express on macOS 14 and must be window-independent
(owned by the store):

- styleMask `[.borderless, .nonactivatingPanel, .resizable]`, `level = .floating`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
  `becomesKeyOnlyIfNeeded = true` (never steals focus), `isMovableByWindowBackground`
  (drag body to move, drag edge to resize), clear/translucent, `minSize`,
  `setFrameAutosaveName` (position + size persist across launches).
- Hosts `CaptionsOverlayView`: a **scroll view auto-pinned to the bottom** showing all
  in-memory lines + the hot partial — no fixed clamp, so as the window grows it shows
  more history and older lines roll off the top as they scroll out (and out of memory
  once `TranscriberModel` flushes them to storage). It reads the SAME
  `MacTranscriptionViewModel` by reference — Observation keeps it live inside the
  `NSHostingView`. Speaker colors come from the shared `SpeakerPalette` (extracted from
  `MacLiveTranscriptionView.speakerColor` so the overlay and main view match).
- **Background:** Liquid Glass (`.glassEffect(.regular, in:)`) on **macOS 26+** (needs
  the Xcode 26 SDK); on older systems a `.ultraThinMaterial` blur with a **configurable
  opacity** (`MacSettingsView` slider → `LiveSessionStore.captionsOpacityKey`).
- Toggle exposed in **both** menus: the main "Recording" menu (`OpenCaptionsCommands`, ⇧⌘C, via
  a new `\.captionsOverlay` focused value) and the `MenuBarExtra` dropdown (via
  `MenuBarState`, so it works window-closed). "Auto-show when recording starts" is
  **on by default** (registered in `OpenCaptionsApp.init` so `LiveSessionStore`'s raw
  `UserDefaults` read sees it before Settings is opened) and toggleable in
  `MacSettingsView` (`@AppStorage(LiveSessionStore.captionsAutoShowKey)`). The scroll
  indicator is hidden (`.scrollIndicators(.hidden)`).

## App Store safety

No new entitlements and no private APIs. Window level + `collectionBehavior` and drawing
our own overlay need no permission — we never read other apps' content (no
screen-recording/accessibility grant for the overlay itself). Background audio uses the
existing audio-input entitlement. Confirmed safe for App Store distribution.

## MVP scope / deferred

Shipped: overlay + show/hide (both menus + shortcut) + auto-show toggle + background
session persistence + **resizable panel**, **auto-scrolling (non-clamped) content**, and
**Liquid Glass / configurable-opacity background**. Deferred (issue follow-ups):
font-size control, click-through (`ignoresMouseEvents`) mode, per-speaker richer styling.

## Files

- New: `OpenCaptions/LiveSessionStore.swift`, `OpenCaptions/Utility/Appearance/SpeakerPalette.swift`,
  `OpenCaptions/Utility/Overlays/CaptionsOverlayController.swift`, `OpenCaptions/Views/LiveTranscription/CaptionsOverlayView.swift`
- Changed: `OpenCaptionsApp.swift`, `ContentView.swift` (preview), `TranscriptionsScreen.swift`,
  `MacLiveTranscriptionView.swift`, `MacLiveTranscriptionView+AudioSource.swift`,
  `MacTranscriptionViewModel.swift`, `MacFocusedValues.swift`, `OpenCaptionsCommands.swift`,
  `MenuBarState.swift`, `MenuBarContent.swift`, `MacSettingsView.swift`
- Deleted: `MacLiveTranscriptionView+MenuBar.swift` (menu-bar wiring moved to the store)
