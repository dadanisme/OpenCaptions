# macOS Global Hotkeys for Transcription Control

**Date:** 2026-07-10
**Target:** OpenCaptions (standalone native macOS app)
**Status:** Implemented

## Problem

Controlling Open Captions required the window to be frontmost (menu shortcuts) or a trip
to the menu-bar item. For a background transcription utility used while the user is
in a meeting/video in another app, that context-switch defeats the purpose. We want
**system-wide** hotkeys to start/stop/pause/resume recording and toggle the captions
overlay — working even when Open Captions is in the background or its window is closed —
plus brief on-screen feedback and a Settings pane to rebind them.

## Why Carbon `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`

Both are viable. We chose **Carbon's `RegisterEventHotKey`** (HIToolbox):

| | Carbon `RegisterEventHotKey` | `NSEvent.addGlobalMonitorForEvents` |
|---|---|---|
| Permission | **None** | Requires **Input Monitoring / Accessibility** grant |
| Event consumed | **Yes** (chord never reaches the frontmost app) | **No** — keys still type into whatever's focused |
| App Sandbox / Mac App Store | **Allowed, no entitlement** | Accessibility grant is friction; monitor still leaks keys |
| Overhead | One registration per chord | A monitor closure on every global key event |

A global monitor that also forwards the keystroke (so ⌃⌥⌘R would both start recording
**and** type into the frontmost app) is unacceptable, and requiring an Accessibility
grant is a large adoption barrier for a Mac App Store app. `RegisterEventHotKey` is the
same permission-free, sandbox-safe primitive that libraries like `KeyboardShortcuts`,
`MASShortcut`, and `HotKey` wrap. We use it directly (no SPM dependency added).

Carbon hotkey events are delivered on the **main run loop / main thread**, so the C
event handler hops onto the main actor via `MainActor.assumeIsolated` and does all work
there.

## Architecture

```
Carbon key event ─▶ hotKeyEventCallback (C, main thread)
                     └─ MainActor.assumeIsolated ─▶ HotKeyManager.handleHotKey(id:)
                                                     └─ perform(action)
                                                        ├─ LiveSessionStore.shared.<op>()   (does the work)
                                                        └─ MacHUDOverlayController.show(...) (feedback)
```

- **`HotKeyManager`** (`@Observable @MainActor` singleton, the `MacAuthManager`/
  `MenuBarState` pattern) owns bindings, Carbon registration, dispatch, and the HUD.
  Carbon glue is split into `HotKeyManager+Carbon.swift` (register/unregister/install +
  the C callback).
- It drives **`LiveSessionStore.shared`**, which already owned the active session
  independently of any window (headless start, end-and-save, pause/resume, captions
  toggle). Routing through the store is exactly what makes the hotkeys work with the
  window closed. Two small state-respecting helpers were added: `pause()` / `resume()`
  (return whether they acted), alongside the existing `togglePause()`.
- **No new dependency, no new entitlement.** The existing sandbox entitlements
  (`OpenCaptions.entitlements`) are sufficient.

## Actions and default chords

Three **toggle** actions — one chord per function, flipping between states (like OBS's
single record/pause hotkeys) rather than five separate start/stop/pause/
resume keys. Each does the right thing for the current state and shows an honest HUD:

| Action | Default | Behavior |
|---|---|---|
| Start / Stop Recording | `⌃⌥⌘R` | starts when idle; Stop & Saves when a session is active (recording, paused, or failed-with-kept-transcript); raises the app if signed out or the mic is denied |
| Pause / Resume | `⌃⌥⌘P` | pauses when recording, resumes when paused; muted no-op note with no session or during the pre-connect window; shows "Couldn't resume" if the socket died during the pause |
| Show / Hide Captions | `⌃⌥⌘C` | toggles the overlay; no-op with no session |

**Why `⌃⌥⌘` ("hyper") defaults instead of `⌘⇧R/S`:** a global
hotkey is captured *system-wide*, so `⌘⇧S` (Save As), `⌘⇧R` (hard-reload), etc. would be
hijacked in every app. `⌃⌥⌘`+letter is essentially never used by macOS or by app menu
shortcuts (which lean on `⌘`/`⌘⇧`/`⌘⌥`), so it meets the goal of avoiding conflicts with
common shortcuts better than `⌘⇧R/S` would. Everything is
user-rebindable in Settings.

## HUD feedback

`MacHUDOverlayController` shows a system-volume-style card (icon + one line) in a
borderless, **non-activating**, `.floating`, all-Spaces `NSPanel` with
`ignoresMouseEvents` — it appears over whatever app is frontmost (including full-screen)
without stealing focus or intercepting clicks. It fades in, holds ~1.1 s, fades out; a
generation counter lets a rapid second press replace the badge instead of being hidden
by the first press's timer. This mirrors the already-working `CaptionsOverlayController`.

Every press shows a HUD — a prominent confirmation for a real change ("Recording
started", "Paused"…) or a **muted** note for a no-op / prompt ("Already recording", "Not
paused", "Microphone access needed"). Feedback matters most when the app is in the
background, so no-ops are surfaced rather than silent.

## Settings pane ("Shortcuts")

A new tab in `MacSettingsView`. Binding is by **press-to-record**: click a row and press
the chord you want. Capture uses a single local `NSEvent` key-down monitor (no
permission — it only sees this app's events while Settings is focused), and
`NSEvent.keyCode` is the same virtual-key space Carbon registers, so the press stores
verbatim; Esc cancels. Each row shows the live chord and a warning when a binding is
**not active**, covering the required conflict handling:

- **Missing modifier** — a chord without at least one of `⌃ ⌥ ⌘` is refused (it would
  clobber normal typing everywhere).
- **Duplicate** — two actions with the same chord: the first registers, the rest are
  flagged.
- **System conflict** — `RegisterEventHotKey` returned non-`noErr` (already owned by the
  system or another app).

The bindings dict is the source of truth; `reregisterAll()` recomputes registrations and
the `issues` map on every edit, so the row always reflects the user's choice and the
warning explains if it isn't active.

## Persistence & launch

Each binding is JSON-encoded under `opencaptions.hotkey.<action>` in `UserDefaults`; corrupt or
missing data falls back to the action's default. `HotKeyManager.start()` (idempotent,
called from `OpenCaptionsApp`'s launch task) loads bindings, installs the one Carbon handler,
and registers everything — so hotkeys are live from launch and survive relaunch.

## Edge cases

- **Start while backgrounded and mic denied / grant missing:** `startHeadlessRecording`
  can't show permission UI headlessly, so the manager brings the app forward, reopens the
  window (via an `openWindow` action stashed on `LiveSessionStore` by
  `WindowOpenerBridge` — the only way non-view code can reopen a SwiftUI `Window`), and
  sets `pendingStartRequest` so the list screen auto-starts and surfaces the mic-permission
  screen.
- **Start while the window is already open and idle:** the headless start creates and
  starts the session; when the live view appears it *rebinds* (its `hasStarted` guard) —
  no double-start.
- **Stop on a failed-but-kept session:** `endFromMenuBar` still saves the kept transcript.
- **Signed out:** Start is gated on `MacAuthManager.isSignedIn` (raises the app); the
  other actions can't fire because no session can exist.

## Out of scope

- Per-user hotkey profiles.
- A dedicated floating-captions build — the captions overlay already exists; the hotkey
  just toggles it.
