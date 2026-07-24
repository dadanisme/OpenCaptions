# macOS app-wide font size (OpenCaptions) — independent of transcript size

**Date:** 2026-07-10 · **Scope:** OpenCaptions

## Problem

Open Captions had exactly one text-size control — the **transcript / captions** multiplier
(`LiveSessionStore.transcriptTextSizeKey`, applied via `Font.transcript(_:multiplier:)`).
The rest of the app chrome (sidebar, session list, session detail + summary, settings,
sign-in) rendered at a fixed system size with no way to scale it. macOS does **not** honor
Dynamic Type for built-in text styles, so `.dynamicTypeSize(...)` is a no-op — there was no
accessibility lever for the general UI.

## Decision

Add a **second, independent** font-size setting that scales the general UI, reusing the
transcript's point-size-multiplier mechanism but with a **separate UserDefaults key** so the
two never affect each other.

| Concern | Choice |
|---|---|
| Storage key | `opencaptions.app.textSizeMultiplier` (`LiveSessionStore.appTextSizeKey`) — distinct from `opencaptions.transcript.textSizeMultiplier` |
| Slider stops | `AppTextSize.steps` = **80,90,…,150, 200, 300 %** — fine 10% increments through 150% for everyday tuning, then coarse 200%/300% jumps for large-text accessibility. Because the jumps are non-uniform, the Settings slider runs on the stop **index** (a uniform-`step` slider can't express 150→200→300). Default 100% = `TranscriptTextSize.defaultMultiplier` (shared). The Settings row shows a live "%" read-out that flags "· Default" at 100%, plus a **Reset** button |
| Scaling math | `Font.scaled(_:multiplier:design:)` — factored out of the old `Font.transcript`, which is now a thin alias. Reads `NSFont.preferredFont(forTextStyle:)`, multiplies its point size, and **preserves its weight** (via the descriptor's weight trait), so each semantic role keeps its system-defined size *and* weight — e.g. `.headline` stays semibold instead of collapsing into regular `.body` (both are 13pt on macOS) |
| Default (1.0) | Pixel-identical to the platform's own point sizes — no appearance change at the default |
| Settings UI | New **General** tab → **Appearance** section in `MacSettingsView`, mirroring the transcript slider. The Settings window itself scales, so the slider previews live |

### Why not `.dynamicTypeSize` / `.scaleEffect`

- **Dynamic Type** — ignored by macOS for built-in text styles (same reason the transcript
  size exists at all).
- **`.scaleEffect`** — scales layout and raster too, overflows the window, and blurs; it is
  not a font-size control.

## Mechanism (`OpenCaptions/Utility/Appearance/AppTextSize.swift`)

Coverage is **broad** (the whole chrome, not just text we author):

1. **`\.appTextScale`** — an `EnvironmentKey` (default `1.0`) carrying the live multiplier.
2. **`.appTextScaling()`** — a root modifier applied once per window/scene root
   (`OpenCaptionsApp`'s main `Window` content group + the `Settings` scene). It reads
   `@AppStorage(appTextSizeKey)` (reactive — moving the slider re-renders every root across
   windows) and does two things:
   - injects `\.appTextScale`, and
   - sets a **scaled default font** (`.font(.scaled(.body, multiplier:))`) so unstyled /
     system-composed text (default button labels, list rows, empty states, nav titles)
     scales too.
3. **`.appScaledFont(_:design:)`** — a drop-in replacement for `.font(<style>)` used on text
   that sets an **explicit** style. Necessary because a plain `.font(.headline)` would
   otherwise **override** the scaled default font (step 2) and stay a fixed size. Reads
   `\.appTextScale` and applies `Font.scaled(style, multiplier:design:)`. The `design:`
   argument carries `.monospaced` where the original used `.font(.<style>.monospaced())`.

### New coding convention

For **Open Captions general-UI** text, use **`.appScaledFont(<style>)`** instead of
`.font(<style>)` so it honors the app-wide setting. This is documented in `CLAUDE.md`.
Two things are deliberately exempt and keep `.font(.transcript(...))`:

- The **live transcript** (`MacLiveTranscriptionView`) and **captions overlay**
  (`CaptionsOverlayView`, a separate window) — they follow the transcript multiplier.
- The transport pill (`MacTranscriptionControls`), transient HUD, and the menu-bar item —
  left on their own sizing; they are not reading content the app-wide lever targets.

## Independence guarantee

The two sliders write different keys and are read by different code paths
(`transcriptTextSizeKey` → `Font.transcript`; `appTextSizeKey` → `.appTextScaling()` /
`.appScaledFont`). The live transcript's core text is always explicitly
`Font.transcript(...)`, so the app-wide default font never overrides it. The captions
overlay is a separate window outside any `.appTextScaling()` root. Changing one size can
never move the other's primary target.

## What does NOT scale (macOS platform boundary)

`.appTextScaling()` reaches SwiftUI **view content** only. Three surfaces are rendered
by the window manager / AppKit outside the content-font environment, and SwiftUI exposes
no font hook for them, so the app-wide slider cannot resize them (this matches native Mac
apps, which scale these only from the *system-wide* setting):

- **Navigation title / subtitle** — window title bar; no `.navigationTitleFont` API.
- **Toolbar items** — hoisted into the toolbar, which normalizes control sizing.
- **App menu bar (`.commands`) + `MenuBarExtra`** — native AppKit menus.

The AppKit-backed sidebar `List` also does not reliably inherit the scaled default font, so
its rows are opted in **explicitly** with `.appScaledFont(.body)` in `ContentView`.

## Notes / trade-offs

- Because `.appTextScaling()` is applied at the main window root, incidental **unstyled**
  text inside the live-recording screen also inherits the app-wide scaled default font. Its
  transcript text (explicitly `Font.transcript`) is unaffected; the drift is limited to
  sparse chrome and is acceptable.
- The 300% ceiling is inherited from the transcript control. It is generous for chrome but
  functional (lists/forms grow and scroll); revisit if a narrower cap is wanted.
