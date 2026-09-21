# macOS: remove Apple Core AI entirely

**Date:** 2026-09-16 · **Scope:** Open Captions target + the deleted sibling `CoreAIPlugin` package
**Supersedes:** `docs/2026-08-12-coreai-parakeet-spike.md` (#44),
`docs/2026-08-12-macos-coreai-plugin-skeleton.md` (#47),
`docs/2026-08-12-macos-coreai-nemotron-streaming.md` (#55) — all now Historical

## Decision

Apple Core AI is gone from this app: the `CoreAIPlugin` SPM package, the `dlopen`
loader, both batch engines, the live streaming engine, the model manager, and the
build phase that produced the dylib.

The cost was never the feature — it was the machinery holding it. Because Apple's
`coreai-models`/`CoreAI.framework` hard-pin `platforms: [.macOS("27.0")]` with no
per-symbol `@available`, and SwiftPM enforces a dependency's platform floor on the
whole consuming target, a 14.4+-floor app could never depend on either directly.
Everything that followed existed to work around that one fact:

- a sibling SPM package built standalone by a Run Script Build Phase,
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the target, because Xcode's script
  sandbox blocks the symlink `swift build` creates,
- a duplicated `@objc` protocol on both sides of a `dlopen` boundary,
- `CoreAIPluginLoader.isAvailable` gates threaded through two engine enums, the
  live picker, the batch picker, and the stale-selection fallback,
- and a second, independent Re-transcription Engine picker that existed *only*
  because Core AI Parakeet was batch-only and otherwise unreachable.

On top of that, the vendored `coreai-models` checkout stopped compiling against
the installed toolchain (`extraneous argument label 'capabilities:'` in
`CoreAILanguageModel.swift`). The script phase swallowed it — it always `exit 0`s
— so every build printed a red `Build failed` from the phase while Xcode still
reported overall success. A build that looks broken but isn't is its own tax.

Three on-device engines remain (FluidAudio Parakeet, FluidAudio Nemotron, Apple
Speech), all reachable both live and in batch, none needing any of the above.

## What went

| Removed | Was |
|---|---|
| `CoreAIPlugin/` | The whole sibling SPM package (`CoreAIParakeetPlugin`, `CoreAINemotronPlugin`, entry point, protocol) |
| `Services/Retranscription/CoreAI/` | `CoreAIPluginLoader`, the duplicated protocol, both post-session engines |
| `Services/Transcription/CoreAI/` | `CoreAINemotronTranscriberService` (the live engine) |
| `Utility/OnDeviceModels/CoreAINemotronModelManager.swift` | Its `OnDeviceEngineModelManaging` conformance |
| `Views/Settings/MacAIModelsSettingsView+Retranscription.swift` | The Re-transcription Engine override row |
| "Build CoreAIPlugin" run-script phase | Built + codesigned + embedded the dylib |
| `MacTranscriptionEngineKind.coreAINemotron` | Live picker case + factory branch + `allCases` gate |
| `RetranscriptionEngineKind.coreAIParakeet` / `.coreAINemotron` | Batch cases + factory branches |
| `RetranscriptionEngineKind.availableCases` | Only ever consumed by the deleted override picker |
| `LiveSessionStore.retranscriptionEngineOverride(Key)` | The override preference |

`ENABLE_USER_SCRIPT_SANDBOXING` is back to `YES` on the target (it was only ever
`NO` for the deleted script phase), matching the project-level default.

## The Re-transcription Engine picker went too

Confirmed with the user rather than assumed. Its own doc comment said it renders
only on macOS 27+, because below that `availableCases` "never offers anything the
live picker above can't already do". With Core AI gone that is true on *every*
OS: the batch enum and the live enum now hold the same four engines, so an
override could only ever restate the live selection.

So `LiveSessionStore.retranscriptionEngineKind` is a plain derivation from
`transcriptionEngineKind` again — which is exactly what `RetranscriptionEngineKind
.forCurrentMode` did before #47 introduced the split. Re-transcription, automatic
re-transcription, and file import all follow the live Transcription Engine
selection, with no separate control.

A stale `opencaptions.retranscriptionEngine.override` value left in UserDefaults
by an older build is simply never read again — no migration needed, since the
only values it could hold were either a Core AI engine (now nonexistent) or a
restatement of the live selection (now the behavior anyway).

## Not done

- **No UserDefaults cleanup pass.** See above — the dead key is inert.
- **The `.claude/worktrees/` copies still contain CoreAI.** They're throwaway
  agent worktrees, not part of the repo's source.
