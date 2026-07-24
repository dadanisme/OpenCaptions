# Open Captions

A native **macOS** app for real-time speech-to-text transcription with speaker
diarization, live captions, and AI-powered summaries. Built with SwiftUI +
SwiftData, targeting macOS 14.4+.

Open Captions captures your microphone **and** other apps' system audio (via Core
Audio process taps, with software echo-cancellation), streams it to a real-time
STT engine, renders a live diarized transcript, and can generate an AI summary
of the session. It also supports a fully on-device **Offline Mode** (Nemotron via
FluidAudio) that needs no network and no metering.

> This is a standalone extract of the macOS app from a larger multi-platform
> codebase, packaged here as a self-contained Xcode project.

## Highlights

- **Real-time transcription** over a WebSocket STT engine (Soniox), with speaker
  diarization and mid-sentence live updates.
- **Mixed mic + system-audio capture** — Core Audio process taps for system audio,
  an `AVAudioEngine` mic tap, and a vendored SpeexDSP-backed acoustic echo
  canceller (the `OpenCaptionsAEC` Objective-C++ class) to remove speaker bleed.
- **Offline Mode** — on-device Nemotron (FluidAudio), free and network-free.
- **AI summaries** of a finished session.
- **Auth & sync** — Firebase Auth (Google / email), Firestore share-to-web.
- **Consumable-minutes billing** — RevenueCat (cloud sessions only; Offline Mode
  is free).
- **Captions overlay** ("open captions"), global hotkeys, app-wide font sizing,
  file import.

## Build & run

1. Open **`OpenCaptions.xcodeproj`** in Xcode (macOS 14.4+ SDK).
2. Set your own **signing team** on the `OpenCaptions` target (currently
   `C4SQMCY5WT`) and, if desired, your own bundle id.
3. Supply credentials (both git-ignored; copy `Config.xcconfig.example` →
   `Config.xcconfig` and provide `OpenCaptions/GoogleService-Info.plist`):
   - **`Config.xcconfig`** (repo root) — `SONIOX_API_KEY`, `SUMMARIZE_API_TOKEN`,
     `DEDUCT_MINUTES_URL`, `REVENUECAT_API_KEY_MACOS`, `REVERSED_CLIENT_ID`.
   - **`OpenCaptions/GoogleService-Info.plist`** — Firebase config.
4. Swift Package Manager resolves the dependencies automatically:
   `FluidAudio`, `firebase-ios-sdk`, `GoogleSignIn-iOS`, `purchases-ios-spm`.
5. Build & run the **`OpenCaptions`** scheme.

> Firebase, Google Sign-In, and RevenueCat are registered to the bundle id
> `com.muhammadramdan.OpenCaptions`. If you change the bundle id, re-register those
> services (or auth/billing will fail at runtime).

## Layout

```
OpenCaptions.xcodeproj   # single macOS target ("OpenCaptions")
OpenCaptions/            # app source: Model, Services, ViewModel, Views, Utility, AEC, ThirdParty
OpenCaptions-Info.plist  # Info.plist template
OpenCaptions.entitlements # app-sandbox + audio-input + Sign in with Apple + keychain group
Config.xcconfig          # secrets (git-ignored) — see Config.xcconfig.example
docs/                    # design & decision notes
```

## Naming note

Renamed to **Open Captions** — the project, scheme, target, product
(`OpenCaptions.app`), display name, permission prompts, **and all file/folder
names** now read Open Captions / OpenCaptions, as do the code symbols
`OpenCaptionsApp`, `OpenCaptionsCommands`, and `OpenCaptionsAEC`.

This app was extracted from a larger multi-platform project; the bundle id
`com.muhammadramdan.OpenCaptions` and its backend are being moved onto
independent Open Captions infrastructure (Firebase project, Cloud Functions,
web session viewer). Because live Firebase / Google Sign-In / RevenueCat were
keyed to the previous bundle id, those services must be re-registered before the
id change takes full effect at runtime.

## Third-party

- **SpeexDSP** (BSD-3-Clause) — a vendored six-file subset under
  `OpenCaptions/ThirdParty/SpeexDSP/`, compiled into the target, backing the echo
  canceller. Not an SPM dependency.

## Notes

- No unit tests are configured; build and run in Xcode.
- App Store distribution uses App Sandbox (no Hardened Runtime / notarization
  required for MAS).
