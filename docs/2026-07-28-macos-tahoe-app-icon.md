# macOS: ship the app icon as `AppIcon.icns`, not an asset-catalog `AppIcon` set

**Date:** 2026-07-28 · **Scope:** Open Captions only
**Verified on:** macOS 26.5.1 (Tahoe, Darwin 25.5) · Xcode 26.5 (17F42)

## Context

The Dock/Finder icon rendered visibly **smaller** than neighbouring apps (Chrome,
Xcode, Notes): the artwork sat inset inside a light-grey rounded "plate" with a
ring of dead space around it, no matter how the PNGs were authored.

Three artwork theories were tried and all failed, because the artwork was never
the problem:

1. Apple's pre-Tahoe "free space" grid (824/1024 body, 22.5% radius) → small.
2. Full-bleed artwork with the rounded corners baked in → still small.
3. A fully **opaque square** with no transparency at all → still small; macOS did
   not even round it, it drew a dark *square* inset on the plate.

## Root cause

On macOS 26 (Tahoe) the system composites app icons itself. How it treats an icon
depends on **how the icon is delivered**, not on how the PNG is drawn:

| Delivery | Tahoe treatment |
| --- | --- |
| Asset-catalog `AppIcon` set built from plain PNG sizes (`CFBundleIconName`) | **Legacy** — artwork is inset and drawn on a light rounded plate |
| Icon Composer `.icon` source, compiled into `Assets.car` | Modern — full-bleed, appearance-aware |
| `.icns` file via `CFBundleIconFile` | Drawn as-is, full size |

Open Captions was in the first row: a `AppIcon.appiconset` of ten PNGs and
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, with no `.icns`. That is what
produced the plate.

The modern renditions are recognisable in a built `Assets.car` — Xcode's and
Notes' own icons compile to names like
`AppIcon1024x1024_NSAppearanceNameSystem_<UUID>.png` (an Icon Composer source),
whereas ours compiled to plain `icon_16.png … icon_512@2x.png`.

Chrome, notably, ships a plain `.icns` via `CFBundleIconFile` and renders at full
size — which is the path adopted here.

## Decision

Ship the icon as **`OpenCaptions/AppIcon.icns`** and point `CFBundleIconFile` at
it, with **no** asset-catalog app icon:

- `OpenCaptions/AppIcon.icns` — the icon (picked up automatically by the
  filesystem-synchronized group; no `project.pbxproj` file entry needed).
- `OpenCaptions-Info.plist` — `CFBundleIconFile = AppIcon`.
- `ASSETCATALOG_COMPILER_APPICON_NAME` **removed** from both build configurations,
  and `Assets.xcassets/AppIcon.appiconset/` deleted.

**Both mechanisms at once does not work.** A bundle carrying an `.icns` *and* an
asset-catalog app icon goes back to the plate — the asset catalog wins. The
appiconset had to go, not merely be supplemented.

## Icon geometry

Because an `.icns` is drawn **as-is**, the rounded-squircle shape must be baked
into the artwork (unlike the modern path, where the system masks it):

- Canvas 1024², **full-bleed body** (no transparent margin), corner radius
  **22.5%** of the body, rendered at 4× supersampling then downscaled.
- The "OC" mark spans **62%** of the tile width; source art
  (`opencaptions-logo-dark.png`, charcoal `#262626`) has the mark at 75.8%, so it
  is rescaled by `0.62 / 0.758`.
- Ten reps (`icon_16x16` … `icon_512x512@2x`) assembled with
  `iconutil -c icns`.

This lands the rendered footprint at **86.7%** of the icon frame — pixel-identical
to Chrome, Xcode and Notes.

## Gotcha: the icon cache lies

Even with a correct build, macOS kept serving the stale plated icon for the
*same* bundle id — a Mac restart did **not** clear it. Verifying an icon change
therefore needs a cache bust, not just a rebuild:

```sh
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DUC=$(getconf DARWIN_USER_CACHE_DIR)
"$LSREG" -u /path/to/OpenCaptions.app
rm -rf "${DUC}com.apple.dock.iconcache" "${DUC}com.apple.iconservices" \
       ~/Library/Caches/com.apple.iconservices.store
killall iconservicesagent; touch /path/to/OpenCaptions.app
"$LSREG" -f /path/to/OpenCaptions.app
killall Dock Finder
```

`${DARWIN_USER_CACHE_DIR}com.apple.dock.iconcache` is the one that actually
matters; clearing only `~/Library/Caches/com.apple.iconservices.store` is not
enough.

To check the real rendering rather than trusting the Dock, render what AppKit
resolves and probe a pixel inside the tile — `(208,208,208)` there means the
plate is back, the artwork colour means it is correct:

```swift
NSWorkspace.shared.icon(forFile: "/path/to/OpenCaptions.app")
```

## Alternate model considered

Apple's documented model is slightly different from what was measured here, and a
future reader should know both. The HIG ("App icons" › Icon shape) and WWDC25
session 220 say the system masks **every** icon to the squircle and that artwork
should be a full-bleed, **opaque, unmasked** square — pre-rounding is explicitly
discouraged ("Providing layers with pre-defined masking negatively impacts
specular highlight effects and makes edges look jagged"). Under that model the
light plate is reserved for *irregularly shaped* icons ("Irregularly shaped icons
receive a system-provided background"), i.e. a silhouette rounder than the system
mask (measured threshold: a baked corner radius past ~28-30%).

On this machine, though, the plate tracked the **delivery path**, not the
silhouette: swapping only appiconset → `.icns` (same artwork, ~22% radius, both
on unsigned test bundles and on the real signed app) turned the plate off. The
`.icns` configuration above is what was verified end-to-end; treat the HIG model
as the intent and this note as the observed behaviour on 26.5.1.

**Side effect worth knowing:** artwork containing any fully transparent pixels
picks up Tahoe's specular/material bevel, so the "OC" mark renders slightly
embossed/silver rather than flat. Fully opaque artwork renders flat. Our `.icns`
has transparent corners by necessity (the shape is baked in), so the mark is
embossed — consistent with how neighbouring apps look, but not identical to the
flat source art.

## Known deferral

The fully native Tahoe treatment (appearance-aware light/dark/tinted icon,
Liquid Glass) needs an Icon Composer `.icon` source, authored in
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app` — a GUI tool
with no headless CLI. The `.icns` path matches neighbouring apps at full size and
is what ships today; adopting `.icon` later would replace `AppIcon.icns` and
restore `ASSETCATALOG_COMPILER_APPICON_NAME`.
