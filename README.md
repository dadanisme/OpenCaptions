# Open Captions

A native **macOS** app for real-time speech-to-text transcription with speaker
diarization, live captions, and AI-powered summaries. Built with SwiftUI +
SwiftData, targeting macOS 14.4+.

Open Captions captures your microphone, other apps' system audio, or both mixed
together (system audio via Core Audio process taps; the mix adds software
echo-cancellation to remove speaker bleed). It streams that to a real-time STT
engine, renders a live diarized transcript, and can generate an AI summary that
also names the speakers it identified. It supports a fully on-device **Offline
Mode** (Nemotron via FluidAudio) that runs without a network once its models have
been downloaded.

All transcription is **free and unmetered** — there is no billing, minute
balance, or paywall in any code path.

> This macOS app began as an extract from a larger multi-platform codebase and is
> now a fully standalone, self-contained Xcode project with its own independent
> backend. No credentials are committed — API keys and Firebase config live in two
> git-ignored files.

## Highlights

- **Real-time transcription** over a WebSocket STT engine (Soniox), with speaker
  diarization and mid-sentence live updates.
- **Three capture sources** — microphone, other apps' system audio (Core Audio
  process taps), or both mixed. The mix runs an `AVAudioEngine` mic tap through a
  vendored SpeexDSP-backed acoustic echo canceller (the `OpenCaptionsAEC`
  Objective-C++ class) to remove speaker bleed.
- **Offline Mode** — on-device Nemotron (FluidAudio), network-free after a one-time
  CoreML model download. Trade-off: English only, no speaker diarization, no custom
  vocabulary, and no AI summary.
- **AI summaries** — a direct call from the app to Google Gemini using your own
  `GEMINI_API_KEY`; there is no backend server in the loop.
- **Automatic speaker naming** — the summary pass names the diarized speakers from
  self-introductions and direct address (Settings → Speaker Names, on by default),
  with manual batch and per-bubble renaming on top.
- **Custom vocabulary** — bias the cloud engine toward names, jargon, and acronyms
  it would otherwise mangle, plus a freeform background note (Soniox paths only).
- **Post-session re-transcription** of a saved session, and **audio import** of an
  existing file.
- **Auth & sync** — Firebase Auth: Google is the primary path and email/password
  works (a Sign in with Apple button is present, but Firebase rejects its token
  audience for the committed custom bundle id). Or skip sign-in entirely as a local
  guest — note a guest is locked to Offline Mode, so no diarization, summaries, or
  sharing. Firestore share-to-web, optionally password-protected — though the share
  **link** currently renders as the relative path `/<sessionId>`, because
  `SESSION_SHARE_BASE_URL` is read from the Info.plist but mapped in neither
  `Config.xcconfig.example` nor `OpenCaptions-Info.plist`.
- **Captions overlay** ("open captions"), a menu-bar item, global hotkeys,
  name-mention notifications, session playback, and independent transcript / UI
  font sizing.

## Build & run

1. Open **`OpenCaptions.xcodeproj`** in Xcode (macOS 14.4+ SDK).
2. Set your own **signing team** on the `OpenCaptions` target (currently
   `C4SQMCY5WT`) and, if desired, your own bundle id.
3. Supply credentials (both git-ignored; copy `Config.xcconfig.example` →
   `Config.xcconfig` and provide `OpenCaptions/GoogleService-Info.plist`):
   - **`Config.xcconfig`** (repo root) — `SONIOX_API_KEY`, `GEMINI_API_KEY`,
     `SUPPORT_EMAIL`, `REVERSED_CLIENT_ID`.
   - **`OpenCaptions/GoogleService-Info.plist`** — Firebase config.
4. Swift Package Manager resolves the dependencies automatically:
   `FluidAudio` (pinned 0.15.5), `firebase-ios-sdk`, and `GoogleSignIn-iOS`.
   The target links FluidAudio, GoogleSignIn, FirebaseAuth, FirebaseFirestore,
   and FirebaseFunctions.
5. Build & run the **`OpenCaptions`** scheme.

Get the keys from [Soniox](https://soniox.com) and
[Google AI Studio](https://aistudio.google.com/apikey). Each key reaches the app
through an `$(...)` substitution in `OpenCaptions-Info.plist` — the first three as
top-level readable keys, `REVERSED_CLIENT_ID` as the OAuth callback URL scheme — so
adding a key to `Config.xcconfig` without a matching plist entry does nothing.

> Firebase and Google Sign-In are registered to the bundle id
> `com.muhammadramdan.OpenCaptions`, which must also match the keychain-access
> group in `OpenCaptions.entitlements`. If you change the bundle id, re-register
> both services or auth will fail at runtime.

## Layout

```
OpenCaptions.xcodeproj    # single macOS target ("OpenCaptions")
OpenCaptions/             # app source: Model, Services, ViewModel, Views, Utility, AEC, ThirdParty
OpenCaptions-Info.plist   # Info.plist template (maps the Config.xcconfig keys)
OpenCaptions.entitlements # app sandbox, audio input, network client, user-selected files,
                          #   Sign in with Apple, keychain group
Config.xcconfig.example   # template for the git-ignored Config.xcconfig
CLAUDE.md                 # architecture & conventions guide
docs/                     # 37 dated design & decision notes
```

## Naming note

Renamed to **Open Captions** — the project, scheme, target, product
(`OpenCaptions.app`), display name, permission prompts, **and all file/folder
names** now read Open Captions / OpenCaptions, as do the code symbols
`OpenCaptionsApp`, `OpenCaptionsCommands`, and `OpenCaptionsAEC`.

This app was extracted from a larger multi-platform project and now runs on its
own independent infrastructure under the bundle id
`com.muhammadramdan.OpenCaptions`. The external surface is: Soniox (the real-time
WebSocket plus `api.soniox.com/v1` for post-session re-transcription), Firebase
Auth and Firestore, two Firebase callables for share passwords, Google Sign-In, a
direct client-side call to Gemini for summaries, and FluidAudio's one-time model
download. Firebase and Google Sign-In are keyed to that bundle id, so a fork
changing it must re-register both.

## Third-party

- **SpeexDSP** (BSD-3-Clause) — a vendored subset under
  `OpenCaptions/ThirdParty/SpeexDSP/`: six compiled `.c` sources (`mdf.c`,
  `preprocess.c`, `fftwrap.c`, `filterbank.c`, `kiss_fft.c`, `kiss_fftr.c`) plus
  their headers, compiled into the target to back the echo canceller. Not an SPM
  dependency. See `ThirdParty/SpeexDSP/README-OPENCAPTIONS.md` for what was
  trimmed and why.

## Notes

- No unit tests are configured; build and run in Xcode.
- App Sandbox is enabled and Hardened Runtime is off, per the Mac App Store
  distribution path chosen in `docs/2026-07-10-macos-distribution.md`. Direct
  distribution outside the MAS would require Hardened Runtime + notarization.
- **No `LICENSE` file yet** — the repo declares no license, so default copyright
  applies until one is added.
- `OpenCaptions/OpenCaptions.storekit` is a leftover from the removed billing
  system. Nothing references it; it can be deleted.
