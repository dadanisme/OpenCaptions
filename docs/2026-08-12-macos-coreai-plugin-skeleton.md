# macOS: Core AI Parakeet isolation-plugin skeleton (#47)

**Date:** 2026-08-12 · **Scope:** Open Captions + a new sibling `CoreAIPlugin` SPM package
**Related:** `docs/2026-08-12-coreai-parakeet-spike.md` (#44 — the spike this issue revisits,
specifically the deferred macOS-27.0-floor question), `docs/2026-08-12-macos-transcription-engine-selector.md`
(#35 — the three-way live picker this extends on the batch/post-session side only)

## Context

#44's spike found Apple Core AI's Parakeet export technically solid but recommended deferring
adoption for two reasons: `apple/coreai-models`' Swift package hard-pins
`platforms: [.macOS("27.0")]`, 13 majors past this app's 14.4+ deployment target, and its export
is batch-only (no streaming). #47 revisits reason (1) specifically: rather than bumping the whole
app's floor, make Core AI Parakeet an engine option available only on macOS 27+ and completely
absent everywhere else.

## Decision: a sibling SPM package + `dlopen`, not a new Xcode target, not `@available`

Confirmed hands-on before writing any app code (this dev machine runs macOS 27.0 / Xcode 27.0,
same as the #44 spike):

- **`coreai-models`' `Package.swift`** declares `platforms: [.macOS("27.0")]` for every target,
  with no per-symbol `@available` annotations anywhere in the source. SwiftPM enforces a
  dependency's platform floor on the *whole consuming target* — `OpenCaptions` (14.4+) can never
  add it as a package dependency, full stop. This is a build-time/target-wide constraint, not a
  runtime one, so `#available(macOS 27.0, *)` cannot work around it: that guards a *call*, not an
  *import*.
- The underlying **system** framework, `CoreAI.framework`, isn't an "existing framework with a
  couple of new annotated APIs" either — its own shipped `.swiftinterface` in the macOS 27 SDK is
  compiled `-target arm64e-apple-macos27.0` with no public symbols below that. There was nothing
  to back-deploy even if `coreai-models` didn't exist.
- Xcode MCP exposes no tool to create a new Xcode target or add a package dependency
  programmatically — only `GetTargetBuildSettings`/`UpdateTargetBuildSetting`/`AddEntitlement`/
  `AddInfoPlist` for an *existing* target. Hand-editing `project.pbxproj` to fabricate an entire
  second `PBXNativeTarget` graph (build phases, configuration lists, an embed-and-sign copy phase,
  a target dependency link) blind, with UUIDs generated and cross-referenced by hand, was judged
  too risky for what a first cut needs.

So: **`CoreAIPlugin/`** is a sibling SPM package (NOT part of `OpenCaptions.xcodeproj`'s package
graph), pinned to `.macOS("27.0")`, built as a `.dynamic` library product (`libCoreAIPlugin.dylib`
— SwiftPM's default `lib`-prefixed naming for a library product). A **single Run Script Build
Phase** on the `OpenCaptions` target (the one pbxproj edit this needed — small and contained
compared to a new target) invokes `swift build -c release` inside it, copies the resulting dylib
into `Contents/Frameworks/`, and codesigns it with the project's own team identity. The app loads
it at runtime via `dlopen`/`dlsym`, gated behind `#available(macOS 27.0, *)` — see
`CoreAIPluginLoader.swift`.

The **only** thing shared between the two independently-compiled binaries is a plain `@objc`
protocol (`CoreAITranscriptionPlugin`), duplicated byte-for-byte in both
`CoreAIPlugin/Sources/CoreAIPlugin/CoreAIPluginProtocol.swift` and
`OpenCaptions/Services/Retranscription/CoreAI/CoreAIPluginProtocol.swift`, with an explicit
`@objc(...)` selector on both sides rather than relying on identical auto-synthesis across two
separate compilations. `OpenCaptions` never `import`s anything from the plugin package — the
factory function is reached through a single `@_cdecl`-exported C symbol
(`makeCoreAITranscriptionPlugin`) looked up by name.

## A real, contained gotcha: Xcode's Run Script sandbox

The first build attempt failed inside the script with permission errors creating the `.build/release`
symlink SwiftPM always produces (`ENABLE_USER_SCRIPT_SANDBOXING`, on by default since recent
Xcode versions, blocks a sandboxed Run Script phase from creating symlinks outside a narrow
allowlist). There's no finer-grained per-phase opt-out for this — the fix was disabling
`ENABLE_USER_SCRIPT_SANDBOXING` for the `OpenCaptions` target (both Debug and Release
configurations). The target has exactly one Run Script phase (this one), so the blast radius of
turning off script sandboxing is limited to it.

The script itself never hard-fails the main app build: if the `CoreAIPlugin` directory is
missing, or `swift build` fails (e.g. an older Xcode/SDK without macOS 27 support — every
contributor without this exact beta setup), it logs a `warning:`-prefixed message and exits `0`.
The main `OpenCaptions` target — 14.4+, no `coreai-models` dependency — builds identically either
way.

## Scope: skeleton only, Parakeet not Whisper, stub not real

Three scope decisions made explicitly during this work, superseding earlier framing:

- **Parakeet, not Whisper.** The issue's own follow-up comment floated Whisper instead (Apple's
  export catalog includes both, and the current `coreai-models` checkout's `CoreAISpeech
  .SpeechRecognitionModel`/`WhisperDecoder` already supports it with the same batch API as
  Parakeet — this was verified, not assumed). Decided against it: Whisper-large-v3-turbo is
  809M params vs. Parakeet's ~600M, float16-only with no quantized export, materially heavier to
  self-host. Nothing about the isolation-plugin architecture is Whisper- or Parakeet-specific —
  this can revisit Whisper later without redoing any of it.
- **This PR is a proven skeleton, not the finished feature.** `CoreAIParakeetPlugin` (plugin side)
  and `CoreAIParakeetPostSessionEngine` (app side) return/relay a canned transcript string —
  no `coreai-models` dependency, no real model, no download flow yet. What's proven end-to-end:
  the sibling package builds inside Xcode's build, the dylib embeds and codesigns correctly, the
  app builds and runs unaffected. Follow-up work: add `coreai-models`' `CoreAISpeech` as the
  plugin's actual dependency, export/host a real `.aimodel` bundle (a GitHub Release asset on
  this repo — no backend to host it otherwise), and a download flow mirroring
  `FluidAudioModelManager`.
- **Live/batch engine selection had to split.** `RetranscriptionEngineKind.forCurrentMode` used to
  derive the batch engine unconditionally from the live `MacTranscriptionEngineKind` selection.
  Core AI Parakeet is batch-only (no streaming path, same as #44 found) and was only ever added to
  `RetranscriptionEngineKind`, never to the live enum — so without an independent choice, it would
  be permanently unreachable through the UI. `LiveSessionStore.retranscriptionEngineKind` replaces
  `forCurrentMode`: an explicit override if one is set (and still available) else the same
  live-derived default as before, so this is a no-op for every existing user unless they
  deliberately set an override. The override picker (Settings → General → "Re-transcription
  Engine") is itself gated to macOS 27+ — below that, `RetranscriptionEngineKind.availableCases`
  never offers anything the live picker can't already reach, so showing a second picker would be
  pure clutter for the overwhelming majority of users not yet on macOS 27.

## What's new

- **`CoreAIPlugin/`** — the sibling package: `Package.swift`, `CoreAIPluginProtocol.swift`
  (protocol), `CoreAIParakeetPlugin.swift` (stub `NSObject` conformer), `CoreAIPluginEntry.swift`
  (`@_cdecl` factory).
- **`OpenCaptions/Services/Retranscription/CoreAI/`** — `CoreAIPluginProtocol.swift` (duplicate),
  `CoreAIPluginLoader.swift` (`dlopen`/`dlsym`, `#available`-gated), `CoreAIParakeetPostSessionEngine.swift`
  (conforms to `PostSessionTranscriptionEngine`; splits the plugin's transcript into one
  `PostSessionToken` per word with evenly-distributed timestamps, mirroring
  `NemotronPostSessionEngine` — the plugin reports only a final string, no per-word timing).
- **`RetranscriptionEngineKind.coreAIParakeet`** — new case in `PostSessionRetranscriptionFactory.swift`,
  plus `availableCases` (filters it out unless `CoreAIPluginLoader.isAvailable`).
- **`LiveSessionStore+TranscriptionEngine.swift`** — `retranscriptionEngineOverrideKey`/
  `retranscriptionEngineOverride`/`retranscriptionEngineKind` replace `forCurrentMode`.
- **`Views/Settings/MacSettingsView+Retranscription.swift`** — the new macOS-27-gated picker,
  split into its own file (mirrors `MacSessionDetailView+Retranscription.swift`'s existing split of
  the same kind of concern) to keep `MacSettingsView.swift` from growing further past budget.
- **`OpenCaptions.xcodeproj/project.pbxproj`** — one new `PBXShellScriptBuildPhase` ("Build
  CoreAIPlugin") appended to the `OpenCaptions` target's build phases; `ENABLE_USER_SCRIPT_SANDBOXING`
  set to `NO` on that target (Debug + Release).

## Follow-ups not taken

- **No real Core AI model wiring** — see "Scope" above. Tracked as the next step on #47.
- **No universal (arm64 + x86_64) plugin binary** — the Run Script phase runs a plain `swift build`,
  which only produces the host machine's native architecture. Not addressed here since Core AI /
  Neural Engine work practically implies Apple Silicon regardless; worth revisiting if that
  assumption turns out wrong.
- **No automated runtime verification of the `dlopen` path or the new Settings picker** — this
  environment has no UI-automation tool for a native macOS window, and `lldb` expression
  evaluation via Xcode MCP hit an unrelated stale-module-cache issue with the existing FluidAudio
  dependency's precompiled modules rather than anything from this change. What *is* verified:
  clean `BuildProject`, the dylib present in `Contents/Frameworks/` and codesigned with the
  project's own team identity (`codesign -dvvv`), and `RunProject` launching without a crash.
  Still owed manually: opening Settings → General and confirming the "Re-transcription Engine"
  section appears with a "Offline (Parakeet, Core AI)" option, and that selecting it and
  re-transcribing a saved session produces the stub transcript end to end.

## Verification

Build the **OpenCaptions** scheme via the Xcode MCP (`BuildProject`) — clean after the script-sandbox
fix, zero errors. `RunProject` launched without a crash; console showed only generic macOS
system-log noise (CoreSpotlight donation failures, same as prior notes). See "Follow-ups" above
for what's still owed as manual verification.
