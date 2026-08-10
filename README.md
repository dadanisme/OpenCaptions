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
> now a fully standalone, self-contained Xcode project with **no backend at all**
> — no accounts, no cloud database. Cloud transcription (Soniox) and AI summaries
> (OpenRouter) are called straight from the app with your own API keys. No
> credentials are committed — API keys live in a git-ignored file.

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
- **AI summaries** — a direct call from the app to OpenRouter using your own
  `OPENROUTER_API_KEY`; there is no backend server in the loop. Routing through
  OpenRouter (rather than a single vendor's API) lets an overloaded upstream be
  retried and routed around instead of failing the summary.
- **Automatic speaker naming** — the summary pass names the diarized speakers from
  self-introductions and direct address (Settings → Speaker Names, on by default),
  with manual batch and per-bubble renaming on top.
- **Custom vocabulary** — bias the cloud engine toward names, jargon, and acronyms
  it would otherwise mangle, plus a freeform background note (Soniox paths only).
- **Post-session re-transcription** of a saved session, and **audio import** of an
  existing file.
- **No accounts, fully local** — there is no sign-in, no cloud database, and no
  web sharing. Every launch goes straight into the local library, and cloud
  Soniox transcription (diarization, custom vocabulary, AI summaries) is
  available to everyone by default. Local markdown/audio export is the only way
  to get a session out of the app.
- **Captions overlay** ("open captions"), a menu-bar item, global hotkeys,
  name-mention notifications, session playback, and independent transcript / UI
  font sizing.

## Build & run

1. Open **`OpenCaptions.xcodeproj`** in Xcode (macOS 14.4+ SDK).
2. Set your own **signing team** on the `OpenCaptions` target (currently
   `C4SQMCY5WT`) and, if desired, your own bundle id.
3. Supply credentials (git-ignored; copy `Config.xcconfig.example` →
   `Config.xcconfig`):
   - **`Config.xcconfig`** (repo root) — `SONIOX_API_KEY`, `OPENROUTER_API_KEY`,
     `SUPPORT_EMAIL`.
4. Swift Package Manager resolves the one dependency automatically:
   `FluidAudio` (pinned 0.15.5).
5. Build & run the **`OpenCaptions`** scheme.

Get the Soniox key from [Soniox](https://soniox.com) and the OpenRouter key from
[OpenRouter](https://openrouter.ai/keys). Each key reaches the app through an
`$(...)` substitution as a top-level readable key in `OpenCaptions-Info.plist` —
so adding a key to `Config.xcconfig` without a matching plist entry does nothing.

## Layout

```
OpenCaptions.xcodeproj    # single macOS target ("OpenCaptions")
OpenCaptions/             # app source: Model, Services, ViewModel, Views, Utility, AEC, ThirdParty
OpenCaptions-Info.plist   # Info.plist template (maps the Config.xcconfig keys)
OpenCaptions.entitlements # app sandbox, audio input, network client, user-selected files
Config.xcconfig.example   # template for the git-ignored Config.xcconfig
CLAUDE.md                 # architecture & conventions guide
docs/                     # 42 dated design & decision notes
```

## Naming note

Renamed to **Open Captions** — the project, scheme, target, product
(`OpenCaptions.app`), display name, permission prompts, **and all file/folder
names** now read Open Captions / OpenCaptions, as do the code symbols
`OpenCaptionsApp`, `OpenCaptionsCommands`, and `OpenCaptionsAEC`.

This app was extracted from a larger multi-platform project and now has **no
backend at all** under the bundle id `com.muhammadramdan.OpenCaptions`. The
external surface is: Soniox (the real-time WebSocket plus `api.soniox.com/v1`
for post-session re-transcription), a direct client-side call to OpenRouter for
summaries, and FluidAudio's one-time on-device model download. Both Soniox and
OpenRouter are gated by a single app-wide API key each, not by any account —
there's nothing to re-register if a fork changes the bundle id.

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
