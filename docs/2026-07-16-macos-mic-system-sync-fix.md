# macOS Mic + System-Audio Sync: Pin the System Ring Latency — #305

**Date:** 2026-07-16 · **Target:** OgmoMac · **Epic:** #103 · **Relates to:** #305 (AEC no effect), #304/#306 (system-audio pitch)

## Problem

After #306 fixed the system-audio pitch-up (#304), a new symptom appeared in the
**Microphone + System Audio** mixed source: the **mic now leads the system audio by
a noticeable, fixed gap**. Separately, #305 reports the software echo canceller
(`OgmoAEC`) has no audible effect. Both trace to **one** cause.

## Root cause (adversarially verified)

The mic `AVAudioEngine` input tap is the mix pacer: each callback it reads `n`
oldest-first samples from `systemRing` (`AudioRingBuffer`, FIFO) and mixes them with
the fresh mic frame. The ring is **seeded** during startup because `start()`
deliberately begins the system tap + drain task **before** `micEngine.start()`
(`MixedAudioCaptureService.swift:116→124→127`): system audio accumulates unconsumed
during the mic engine's spin-up. Reading oldest-first means the system audio in the
mix lags the mic by that ring occupancy.

**Why #306 unmasked it (it did not create it).** On a 44.1 kHz-output machine the
pre-#306 `convert()` produced ~14,700 samples/s (`16000/48000` ratio on 44.1 kHz
frames) while the mic pacer consumes 16,000/s. Production < consumption, so the ring
chronically **drained** to near-empty — small lag, but choppy + pitched. The pitch
bug was silently draining the latency away. #306 made production == consumption, so
the startup seed now **freezes** in the ring → a fixed, noticeable offset. The
latency was always in the pipeline; the rate bug had been hiding it. (This entire
story is specific to the 44.1 kHz machines that reported the pitch bug — on a native
48 kHz output device there was no drain and no masking.)

**Why the AEC (#305) does nothing.** The far-end reference fed to `OgmoAEC` *is* the
ring-read (lagged) system span (`+Mic.swift:132→139`), so it lags the near-real-time
mic echo by the ring occupancy (hundreds of ms). SpeexDSP's MDF canceller is
**causal** with a 200 ms tail (`OgmoAEC.mm:30`): it can only model echo appearing at
or after its reference. A reference that lags the echo is a negative delay — outside
the model — so nothing cancels. `setStreamDelayMs` only *adds* reference delay
(`OgmoAEC.mm:104-105`), the wrong direction, and is called with `0` anyway.

So it is one latency with two faces: the audible/transcript skew, and the
uncancellable AEC reference.

## Fix — pin the ring to a small target latency (Option A)

Replace the ring's full-capacity-only drop-oldest as the occupancy governor with an
active **trim before each read**:

- `AudioRingBuffer.trim(toMaxAvailable:)` — drops the oldest samples so at most
  `maxAvailable` remain; returns the pre-trim occupancy (for instrumentation).
- The mic pacer calls `systemRing.trim(toMaxAvailable: n + systemRefCushionSamples)`
  immediately before `read(into:count:n)` (`+Mic.swift`).

Post-#306 the startup seed always exceeds `n + cushion`, so the first trimmed read
discards it and — because production == consumption — occupancy then **holds** at
`cushion`. The kept cushion is the same buffer used as the AEC far-end reference and
re-added as clean system audio, so shrinking it shrinks the perceived gap *and* the
reference lag in lockstep, while preserving an anti-underrun margin (a plain flush to
zero, "Option B", would underrun constantly: the bursty mic reader vs. the jittery
cooperative-pool drain task would zero-pad → a gapped reference makes Speex diverge).

### Tunable

`MixedAudioCaptureService.systemRefCushionSamples` — the steady-state look-behind,
simultaneously the underrun cushion and the residual reference-lag floor. **Start
800 = 50 ms**: above a typical ~10-12 ms aggregate IO block + drain jitter, well
inside the 200 ms Speex tail. Tune DOWN toward ~480 (30 ms) once on-device numbers
are in; raise if the reference goes choppy.

## Instrumentation (to close the two unknowns)

Two quantities are not derivable from source and gate whether Option A alone fully
cures #305. `recordMixStats` (`+Stats.swift`) accumulates cheap per-callback counters
on the render thread and flushes ~1 s to Console (subsystem
`com.muhammadramdan.OgmoMac`, category `MixedAudio`), one line:

```
mix align: n=<avg> [<min>…<max>] (<ms>/callback); ring occupancy=<ms>; underrun=<%> (cushion=50 ms)
```

- **`n` (mic tap buffer size)** — `installTap(bufferSize: 0)` is only a hint. If
  macOS hands back ~100 ms buffers, the residual gap is `n`-dominated, not the
  cushion, and Option C is needed.
- **`ring occupancy`** — should collapse from the startup seed to ≈`cushion`.
- **`underrun`** — must stay ≈0 %; a rising figure means the cushion is too small
  (choppy reference → Speex diverges) → raise the cushion.

## Deferred / follow-ups

- **Option C — near-end mic delay.** If measurement shows the reference *still* lags
  the mic echo at a safe cushion (i.e. the system tap-pipeline latency exceeds the
  built-in-speaker echo round-trip), the mic must be *delayed* to align — the
  opposite sign from `setStreamDelayMs`. Not implemented; enable only after
  measurement (a small pre-delay line on the downmixed mic before the AEC/ re-add,
  or a symmetric near-end knob on `OgmoAEC`).
- **Option D — `setStreamDelayMs`.** Kept at 0; wrong direction for the confirmed
  failure. Reserve purely as post-Option-A fine-alignment once the reference is
  confirmed to *lead* the echo, to trim residual lead within the tail.

## Files

- `OgmoMac/Services/Audio/AudioRingBuffer.swift` — add `trim(toMaxAvailable:)`.
- `OgmoMac/Services/Audio/MixedAudioCaptureService.swift` — `systemRefCushionSamples`
  constant + mix-stat counters.
- `OgmoMac/Services/Audio/MixedAudioCaptureService+Mic.swift` — trim before read;
  record stats.
- `OgmoMac/Services/Audio/MixedAudioCaptureService+Stats.swift` — `recordMixStats`.

## Verification

Build the **OgmoMac** scheme in Xcode. Source = **Microphone + System Audio**, on
**built-in speakers** with audible bleed, a **fresh session** (the AEC builds at
session start only). Confirm: (1) the mic-leads-system gap collapses to ~50 ms;
(2) in Console the `mix align` line shows `ring occupancy` settling near the cushion
with `underrun` ≈0 %; (3) remote participants are transcribed once (AEC engaged —
the `OgmoAEC ready` line confirms it built). Read the logged `n` and occupancy to
decide whether to lower the cushion or add Option C. Validate on a **stably-signed**
build inside the sandbox (dev signing forgets the Audio-Recording TCC grant each
launch). CI: `scripts/check-file-length.sh OgmoMac`.
