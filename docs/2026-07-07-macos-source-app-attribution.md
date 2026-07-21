# macOS source-app attribution (OgmoMac)

**Date:** 2026-07-07
**Target:** `OgmoMac` only (not the iOS `unmute` target)
**Status:** v1 shipped behind no flag; live view + saved sessions + captions overlay.

## Goal

Show, per transcript line, a small **app icon** indicating which app the audio came
from — the "option-1" design from the earlier feasibility discussion. Rendered as
`[app icon] · timestamp · Speaker X`. **Icon only, no app-name text**: the icon
carries the app identity, the diarized "Speaker X" label is unchanged.

## The hard constraint (why this is a heuristic)

`SystemAudioTapCaptureService` captures system audio with a **single global mixdown
tap** — `CATapDescription(monoGlobalTapButExcludeProcesses:)`. Every app's output is
blended into one mono stream *before* we see it, so a line's audio **cannot be split
by app from the stream itself**. Exact per-app audio would require the "option-2"
per-app-tap rearchitecture (one `initMonoMixdownOfProcesses:` tap per app); that was
explicitly deferred.

Instead we run a **separate activity time-series** and correlate by time:

- `SystemAudioActivityMonitor` polls Core Audio every 0.5 s for processes whose
  `kAudioProcessPropertyIsRunningOutput == 1`, resolves each to a **user-facing app**
  (see below), excludes OGMO itself, and records `{sessionRelativeMs, [bundleID]}`
  samples. The sample clock is anchored to the view model's `sessionStart`, so it lines
  up with the line `startMs`/`endMs` (both stamped from `totalActiveTime`, *not*
  wall-clock — Soniox's own token times are unreliable).
- At line commit (`saveTranscriptionLine`), `dominantApp(fromMs:toMs:)` returns the id
  appearing in the most samples across the line's window (a **named app** wins over the
  unknown-system-audio marker; ties → most recent), or **nil if nothing was outputting**
  — meaning the line is the user's own mic.

### Resolving a process to its owning app (why this is non-trivial)

The process that *opens* the audio stream is often NOT the user-facing app:

- **Native apps** (WhatsApp, Apple Music) render their own audio → the process is the
  app → resolves directly via `NSRunningApplication(processIdentifier:)`.
- **Chromium/Electron apps** (Chrome, Steam, Discord) render audio in a renderer/GPU
  **helper** that is a *child* of the main app process. `AppProcessResolver` walks the
  parent-PID chain (public `sysctl(KERN_PROC_PID)`). Two helper shapes occur: some
  helpers aren't launchable at all (Chrome) → we skip them and take the parent; others
  *are* launchable but have a **blank** icon (Steam's `com.valvesoftware.steam.helper`,
  Electron `*.helper.*`) → we collapse them by **bundle-id prefix** (an ancestor whose
  bundle id is a dotted prefix of the helper's is the owning app). Both paths reach
  Chrome/Steam/Discord, fixing the earlier blank-helper-icon bug.
- **OS-mediated audio** (Safari/WebKit, FaceTime) is produced by a **shared macOS
  service** — WebKit's `com.apple.WebKit.GPU`/`WebContent` XPC processes and FaceTime's
  `avconferenced`/`callservicesd` daemons. Critically, the WebKit GPU process *reports
  itself as a running app* (`NSRunningApplication` returns it with a non-prohibited
  policy), but `com.apple.WebKit.GPU` is **not launchable** (no app URL / icon). So the
  walk's acceptance test is "resolves to a **launchable** app," not merely "is a running
  app" — WebKit processes fail it and the walk continues up to the hosting app (Safari)
  when reachable. If the chain hits `launchd` first, the process gets the
  **unknown-system-audio marker** (`SourceAppMarker.unknownSystemAudio`) → neutral
  speaker glyph. **Note: the deferred "option-2" per-app tap would NOT fix this** — the
  app's own process isn't the one making the sound. This is a limit of how macOS routes
  that audio, not of the tap topology.

**Accuracy:** clean when one app plays at a time (a Zoom call, one video); ambiguous
when several overlap. This is documented as best-effort, not ground truth.

## Behaviour across capture modes

Three per-line states: **app icon** (resolved to a named app), **neutral speaker glyph**
(system audio detected but unattributable), **nothing** (no output → your mic).

| Mode | Monitor runs? | App playing (named) | App playing (unnameable) | Nothing playing |
|---|---|---|---|---|
| `microphone` | no | — | — | nothing (unchanged) |
| `systemAudio` | yes | app icon | speaker glyph | nothing |
| `microphoneAndSystem` | yes | app icon | speaker glyph | nothing (your mic) |

`AudioSource.capturesSystemAudio` gates the monitor. There is **no reserved icon slot**:
a mic line renders exactly as before, so a leading glyph (icon or speaker) reads as
"this line is app / system audio." In mixed mode that's the mic-vs-system signal.

The monitor lifecycle (`MacTranscriptionViewModel+AppMonitor`): started in `start()`
when the source captures system audio, torn down on stop/discard/failure, paused with
the soft pause, and **reconciled on a live source swap** (begins on Mic→System, ends on
System→Mic — lines committed before a swap correctly get no app, since no samples cover
them).

## Persistence

`TranscriptionLine.sourceAppBundleID: String?` (nullable → automatic SwiftData
lightweight migration) stores the bundle id so **saved sessions and the captions
overlay** show the icon too, not just the live view. Threaded through the in-memory
`TranscriberModel.sourceApps` parallel array and both persistence sites
(`extractOldLines`/`persistLines` mid-session flush, and `saveSession` on stop).

`AppIconResolver` maps a bundle id → cached `NSImage` (via `NSWorkspace`) for the
`SourceAppIcon` view; the `unknownSystemAudio` marker instead renders a neutral
`speaker.wave.2.fill` glyph.

## Bubble splitting on app change

Within a same-speaker run, `flushSentence` normally merges sentences into one bubble.
It now compares each sentence's `dominantApp` against the current bubble's app
(`finalLines.sourceApps.last`) and **forces a new bubble when the app changed** — so
each bubble's glyph reflects a single app, mirroring the existing speaker-change split.
Granularity is the sentence boundary (bubbles split between sentences, not mid-sentence;
a sentence spanning an app change resolves to its window's dominant app).

## Known limitations / caveats (v1)

1. **Heuristic, not exact** — overlapping apps can't be disambiguated (global mixdown).
2. **Daemon false-positives (watch item)** — a mic line gets the neutral speaker glyph
   only if some process reports `IsRunningOutput` during its window. If a background
   audio daemon (e.g. `coreaudiod`) ever shows as output-active during silence, a
   mic line in Mic+System mode could wrongly show the glyph. DEBUG logging (`audio-out …`)
   is left in to catch this; if it happens, filter such processes.
3. **Latency reference frame** — both the line times and the activity samples carry
   Soniox's finalization latency, so they share a frame and correlate consistently; the
   attribution is not skewed relative to the transcript.

## Files

- New: `Services/SystemAudioActivityMonitor.swift`, `Utility/AppIconResolver.swift`,
  `Utility/AppProcessResolver.swift` (PID→app parent-walk + `SourceAppMarker`),
  `Views/SourceAppIcon.swift`, `ViewModel/MacTranscriptionViewModel+AppMonitor.swift`.
- Core Audio helpers added to `Services/CoreAudioTapUtils.swift`
  (`processObjectList`, `isRunningOutput`, `pid(for:)`, `bundleID(for:)`).
- Model: `TranscriptionLine.sourceAppBundleID`, `TranscriberModel.sourceApps`,
  persistence plumbing.
- VM: `appMonitor` on `MacTranscriptionViewModel`; stamp in `+Accumulator`; pause/resume
  in `+Lifecycle`; swap reconcile in `+AudioSource`.
- UI: `SourceAppIcon` prepended in `MacLiveTranscriptionView`, `MacSessionDetailView`,
  `CaptionsOverlayView`.
