# macOS System-Audio Capture Pitched Up — Aggregate Rate Fix — #304

**Date:** 2026-07-16 · **Target:** OpenCaptions · **Epic:** #103 · **Fixes:** #304

## Problem

System audio captured via the Core Audio process tap plays back **pitched up
~9%** (chipmunk), with duration/speed roughly unchanged. Affects both the
**System Audio** (`.systemAudio`) and **Microphone + System Audio**
(`.microphoneAndSystem`) sources; **Microphone-only is unaffected**. The two
affected modes share one code path: `MixedAudioCaptureService` reuses
`SystemAudioTapCaptureService` as-is for its system half, so the defect is
isolated to the process-tap capture/conversion — **not** the AEC (System-Audio-only
never runs the canceller yet shows the same artifact) and **not** the mic path.

## Root cause (confirmed)

A **sample-rate mismatch** in the tap→16 kHz conversion.

`SystemAudioTapCaptureService.buildAndStart()` built a whole-system process tap,
then cached the tap's native format **once** from `kAudioTapPropertyFormat`
(typically **48 kHz**) and used that to interpret **every** IOProc buffer.

But the IOProc is installed on the **aggregate device**
(`AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, …)`), not on the raw
tap. An aggregate presents a single clock domain set by its **main sub-device**
(`kAudioAggregateDeviceMainSubDeviceKey` = the default **OUTPUT** device). The
sub-tap's samples are drift-compensated (`kAudioSubTapDriftCompensationKey: true`)
and delivered to the IOProc **at the aggregate's nominal rate** — e.g. **44.1 kHz**
on a 44.1 kHz output device — *not* the tap's native 48 kHz. (Drift compensation
is precisely the mechanism that resamples the tap *to* the aggregate clock; it does
not deliver the tap's native rate.)

`convert()` computes the resample ratio as `outputFormat.sampleRate /
source.sampleRate` = `16000 / 48000`, telling `AVAudioConverter` the input is
48 kHz-rate audio when it is really 44.1 kHz. It emits ~8% too few output frames,
which — played at the 16 kHz label — is `48000 / 44100 = 1.0884` ≈ **+8.84% pitch
(≈1.5 semitones)**, exactly matching the report. The strict content duration is
~8% short, subtle enough to read as "roughly unchanged" next to the obvious pitch.

**Only the resample ratio is corrupted.** The no-copy `frameLength` is correct
regardless of the rate label: `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)`
derives it from `mDataByteSize / mBytesPerFrame`, and `mBytesPerFrame` (4 bytes for
Float32 mono) is rate-independent.

Why the **mic paths are immune**: `MacAudioService` and `MixedAudioCaptureService+Mic`
read the **live** buffer's sample rate every callback and rebuild the converter on
change, so they never trust a stale cached rate.

Reference point: `insidegui/AudioCap` has the same latent assumption (reads the tap
format once, never re-reads the aggregate) and escapes the bug only because typical
built-in Mac output *and* the tap are both 48 kHz — it would pitch up identically on
a 44.1 kHz output device.

## Fix

Derive the source **rate** from the **aggregate's nominal sample rate**
(`kAudioDevicePropertyNominalSampleRate`) — the master clock the HAL sets from the
main sub-device at aggregate creation — and override only `mSampleRate` on the tap's
ASBD (keeping its rate-independent channel count / format flags). Set `sourceFormat`
**after** aggregate creation but **before** IOProc install / `AudioDeviceStart`, so
no IOProc callback ever observes an unset or stale format (no lock needed). Since
`convert()` already rebuilds the converter when `inputFormat != source`, a correct
`sourceFormat` is self-consistent.

- New helper: `CoreAudioTapUtils.nominalSampleRate(_:)` (reuses the existing
  `property<T>` HAL reader with `Float64`).
- `buildAndStart()`: `asbd.mSampleRate = aggRate` when the read succeeds and
  `aggRate > 0`.

### Why nominal rate, not the input-stream format

Reading `kAudioDevicePropertyStreamFormat` / `kAudioStreamPropertyVirtualFormat` on
the aggregate's input scope *also* carries the right rate, but adversarial review
flagged two hazards the nominal-rate read avoids: (1) a **pre-`AudioDeviceStart`
settling race** where the stream's virtual format may still report the tap-native
48 kHz before the device locks to its master clock, and (2) an **empty input-stream
list** immediately post-creation (HAL race) that would throw and turn a working
start into a hard failure. `kAudioDevicePropertyNominalSampleRate` is deterministic
at creation and needs no stream enumeration. Re-reading `kAudioTapPropertyFormat`
after aggregate creation does **not** help — the tap still reports its own 48 kHz.

### Fail-soft, no regression

If the nominal-rate read fails (`try?` → nil) or returns 0, we keep the tap's
native rate — identical to today's behavior. On a genuine 48 kHz output device the
override is a no-op. So the change can only *fix* the mismatched case and never
regresses a currently-working path into a start failure.

## Scope / deferred

- **Mid-session same-device rate renegotiation** (e.g. Audio MIDI Setup changes the
  output device's rate without changing *which* device is default) is **not**
  handled: `sourceFormat` could go stale and the pitch-up return for that session.
  A self-heal listener on the aggregate's nominal rate was considered and
  **deferred** — it is unproven on a *private* aggregate (may never post), adds a
  new session-kill vector, would run blocking HAL reads on the audio `ioQueue`, and
  introduces a teardown race. This is narrow and never affects a fresh session (the
  static fix corrects every new session). Tracked as a follow-up if it surfaces.
- **Default-output-device *change*** keeps the existing policy: the
  `+Listeners` output-device listener fires `onInterruption` → the owner fails the
  session (keeping the transcript). The aggregate is pinned to the old device UID
  and cannot follow a new default, so failing is correct; consistent with this
  target's documented "no hot rebuild / no reconnection" design.

## Files

- `OpenCaptions/Services/Audio/CoreAudioTapUtils.swift` — add `nominalSampleRate(_:)`.
- `OpenCaptions/Services/Audio/SystemAudioTapCaptureService+IO.swift` — derive
  `sourceFormat`'s rate from the aggregate after creation.
- `OpenCaptions/Services/Audio/SystemAudioTapCaptureService.swift` — updated
  `sourceFormat` doc comment.

## Verification

Build the **OpenCaptions** scheme in Xcode. On a machine whose **default output device
runs at 44.1 kHz** (the failing case): pick **System Audio** (and **Microphone +
System Audio**), play reference music/speech, record, Stop & Save, and confirm
playback is at natural pitch. Re-confirm on a 48 kHz output device (no regression),
and confirm **Microphone-only** is unchanged. To force 44.1 kHz for the test, set
the output device rate in **Audio MIDI Setup**. Validate on a **stably-signed**
build inside the sandbox (dev signing forgets the Audio-Recording TCC grant each
launch). CI: `scripts/check-file-length.sh OpenCaptions`.
