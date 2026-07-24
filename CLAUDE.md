# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Open Captions** — a native **macOS** app for real-time speech-to-text transcription with speaker diarization, live captions, and AI summaries. SwiftUI + SwiftData, macOS **14.4+**. It is **not** Mac Catalyst and shares no code with any other platform: it was extracted from a larger multi-platform codebase into this standalone project, now fully separated with its own independent backend. Uses Firebase (Auth, Firestore, Functions), Google Sign-In, and FluidAudio (on-device inference). All transcription is **free and unmetered** — there is no billing, metering, or paywall.

Core flow: capture mic **and/or** other apps' system audio → stream to a real-time STT engine → render a live diarized transcript → save to local SwiftData → optional AI summary. A fully on-device **Offline Mode** (Nemotron via FluidAudio) needs no network.

## Naming — fully renamed to Open Captions

The app was extracted from a larger multi-platform codebase and has since been **fully renamed and separated** into a standalone **Open Captions** project. The rename is complete: no legacy branding remains in the committed source, symbols, UI copy, or identifiers.

- **Xcode + files:** project/scheme/target/product (`OpenCaptions.app`), display name, Info.plist strings, and all file/folder/asset names (`OpenCaptions/`, `OpenCaptionsApp.swift`, `OpenCaptionsAEC.{h,mm}`, `opencaptions-logo`, …).
- **Bundle id:** `com.muhammadramdan.OpenCaptions` — set in `project.pbxproj`, the `OpenCaptions.entitlements` keychain-access group, and 3 audio `Logger(subsystem:)` labels. Core Audio self-process identification reads it dynamically via `Bundle.main.bundleIdentifier`, so it needs no per-file literal.
- **Code symbols:** `OpenCaptionsApp` (the `@main` struct in `OpenCaptionsApp.swift`), `OpenCaptionsCommands`, and `OpenCaptionsAEC` (the Obj-C class in `OpenCaptionsAEC.{h,mm}`, exposed through `OpenCaptions-Bridging-Header.h`). Type names now match their file names.
- **UI copy:** every user-facing string reads "Open Captions".
- **Misc identifiers:** Carbon four-char hotkey code `'OpCp'` (`0x4F704370`); window autosave name `"OpenCaptionsCaptionsOverlay"`; UserDefaults keys `opencaptions.*`; the SpeexDSP include guard `OPENCAPTIONS_SPEEXDSP_CONFIG_H`.
- **Backend / services:** the app depends on an **independent** Firebase project, Google Sign-In OAuth client, and Cloud Functions — all supplied per-deployment via the git-ignored `Config.xcconfig` and `GoogleService-Info.plist`; **no infra is hardcoded in committed source.** The support email is config-driven (`SUPPORT_EMAIL`). The former summarization endpoint (`SUMMARIZE_URL`) and web-share base URL (`SESSION_SHARE_BASE_URL`) config keys were **removed** — AI summaries await migration to a direct Gemini call, so `SummaryService` currently has no endpoint. A developer moving to their own backend must re-register these services against their new bundle id and fill in the two git-ignored files.

## Build & Run

Open `OpenCaptions.xcodeproj` in Xcode (macOS 14.4+ SDK), select the **`OpenCaptions`** scheme, build & run. There are **no unit tests**. Build in Xcode — do not rely on a `xcodebuild` CLI flow.

The committed signing team is `C4SQMCY5WT`; a different developer must set their own team (and, to run live services, their own bundle id + re-registered Firebase/Google).

**Filesystem-synchronized groups** (Xcode 16 `PBXFileSystemSynchronizedRootGroup`): new files added anywhere under `OpenCaptions/` are picked up **automatically** — never hand-edit `project.pbxproj` to add a file. Only *build-setting paths* (Info.plist, entitlements, bridging header, header search paths) live in the pbxproj.

### Credentials (both git-ignored)

- **`Config.xcconfig`** (repo root) — injected into the build; keys: `SONIOX_API_KEY`, `SUPPORT_EMAIL`, `REVERSED_CLIENT_ID` (Google OAuth callback). Copy `Config.xcconfig.example` to start.
- **`OpenCaptions/GoogleService-Info.plist`** — Firebase config, loaded from the bundle at launch.

## Architecture (MVVM + Services)

Source is under `OpenCaptions/` (`Model/`, `Services/`, `ViewModel/`, `Views/`, `Utility/`, `AEC/`, `ThirdParty/`). The pieces that need several files to understand:

- **Transcription state machine** — `MacTranscriptionViewModel` (+ 7 `+` extension files: `+Accumulator`, `+AudioSource`, `+AudioRecording`, `+Engine`, `+Firestore`, `+Lifecycle`, `+AppMonitor`) drives a session. A session **outlives its window**, so session-scoped state (the keepalive) lives on the view model / stores, never on a view. `failSession(message:)` is the single abort path (connection loss, mic failure, audio-route change): it stops capture and closes the socket **while keeping the transcript**, so Stop & Save still persists what was captured.

- **Cloud STT (Soniox)** — `Services/Transcription/OnlineTranscriberService` (+`+ConnectionHealth`, `+Messages`) is a `URLSessionWebSocketTask` client to `wss://stt-rt.soniox.com`. The JSON config is sent as the **first frame** right after `resume()` (sends queue FIFO until open — no startup sleep). During a soft pause a 15 s `RunLoop` keepalive holds the idle socket under Soniox's ~20 s timeout; because macOS **App Nap** throttles that timer when backgrounded, a `ProcessInfo.beginActivity(.userInitiated)` assertion is held for the whole running-or-paused session (also disables idle sleep).

- **On-device STT (Offline Mode)** — Nemotron / Parakeet via **FluidAudio** (`Services/Transcription/*` + `Utility/OnDeviceModels/FluidAudio*`). English-only, single-stream, unmetered. Post-session re-transcription lives in `Services/Retranscription/`.

- **Audio capture** — `Services/Audio/`. Mic via an `AVAudioEngine` input tap → 16 kHz mono (no `AVAudioSession` — macOS has none). **System audio uses Core Audio process taps** (`SystemAudioTapCaptureService` + `CoreAudioTapUtils`), **not** ScreenCaptureKit. The mixed mic+system source (`MixedAudioCaptureService`) uses a **plain** mic engine (no VPIO — the mic tap must stay passive/read-only) and cancels speaker bleed **in software** via `OpenCaptionsAEC` — an Obj-C++ bridge (`AEC/OpenCaptionsAEC.{h,mm}`, exposed through `OpenCaptions-Bridging-Header.h`) over a **vendored six-file SpeexDSP subset** (`ThirdParty/SpeexDSP/`, pure C, BSD-3, compiled into the target — not SPM).

- **Metering** — none. All transcription (cloud Soniox and Offline Mode) is free and unmetered: there is no minute balance, deduction, gate, or paywall. RevenueCat and the whole billing subsystem (`MacSubscriptionManager`, `MacMinuteDeductionService`, the `MacTranscriptionViewModel+Billing` clock, `MacPaywallView`, `MacUsageSettingsView`) were removed; every session start, re-transcription, and file import is always-allowed.

- **Auth & scoping** — `Utility/Auth/MacAuthManager` (+`+Apple`, `+Email`, `+Google`, `+Onboarding`, `+AccountDeletion`). Sign-in is **required** (`OpenCaptionsApp` gates the main UI vs sign-in). **Google Sign-In is the primary path**; email/password works; the Apple button exists but is **hidden**. Sessions are scoped by Firebase uid; `SessionOwnerBackfill` claims legacy rows at launch.

- **Sync & sharing** — `Services/Sync/FirestoreSyncService` (+ `+LineSync`, `+SessionSync`, `+Writes`, `+UserPrefs`) mirrors live sessions to Firestore for web viewing; `SessionLinkSharer` promotes a finished session; `SessionPasswordService` password-protects a share.

- **App shell & windowing** — `OpenCaptionsApp` (`Window` scene + a separate menu-bar `MenuBarExtra` scene), `OpenCaptionsCommands` (menu commands reading `@FocusedValue`), `LiveSessionStore` / `MenuBarState` as app-wide observable stores. Global hotkeys (`Utility/HotKeys/`, Carbon), a captions overlay + HUD (`Utility/Overlays/`), name-mention highlight/notify (`Utility/NameMention/`), and file import (`Services/Import/`).

- **Appearance** — **two independent font-size sliders**: the transcript/captions size (`Font.transcript`, applied in `MacLiveTranscriptionView` / `CaptionsOverlayView`) and the app-wide UI size (`Utility/Appearance/AppTextSize.swift`, applied via `.appScaledFont(_:)` + a root `.appTextScaling()`). They write different keys and never affect each other.

## Coding Standards

The code was written under these conventions — keep matching them:

- **~250-line limit per file** — split responsibilities across `Type+Feature.swift` extension files (see the many `MacTranscriptionViewModel+*` / `MixedAudioCaptureService+*` files) rather than growing one file.
- **macOS ignores Dynamic Type** — never hardcode point sizes for general UI. Use **`.appScaledFont(_:)`** (not `.font(_:)`) on sidebar/list/detail/settings/sheets so text honors the app-wide font setting; unstyled text inherits the scaled default. The live transcript + captions overlay are the exceptions (they use `Font.transcript(...)`, the separate transcript-size mechanism).
- `camelCase` / `PascalCase` / `UPPER_CASE`; boolean `is`/`has`/`should`/`can`/`will`; `async/await` over completion handlers with `[weak self]`; no force-unwraps/force-tries; `// MARK:` sections; one clear responsibility per file.

## Documentation

`docs/` is the knowledge base — dated design/decision notes (`{YYYY-MM-DD}-{topic}.md`) covering the audio pipeline, AEC, system-audio capture, billing, auth, onboarding, and more. Consult it before changing a subsystem; add a note there for any non-obvious design/threshold/trade-off decision.

## Known deferrals

- No Analytics; no localization (UI strings are hardcoded English); Apple Sign-In hidden (Firebase token-audience mismatch; revisit once the new backend is registered).
