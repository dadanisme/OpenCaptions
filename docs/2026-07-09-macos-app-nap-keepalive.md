# macOS: harden the background WebSocket keepalive against App Nap

**Date:** 2026-07-09
**Issue:** #174 (parent epic #103, depends on the MVP #171)
**Target:** `OgmoMac` (standalone native macOS app) only. The iOS `unmute` target is untouched.

## Problem

macOS **App Nap** throttles a backgrounded or occluded app: it coalesces
`RunLoop.main` timers (routinely deferring them by tens of seconds), lowers
scheduling priority, and can defer timer-based network sends. A long
transcription session in OgmoMac keeps the Soniox WebSocket alive with
`RunLoop.main` timers, so App Nap can silently stall it while the window isn't
frontmost.

### The sharp failure: a paused session

`OgmoMac`'s connection health lives entirely on two `RunLoop.main` timers in
`OnlineTranscriberService`:

| Timer | Interval | Runs when | App Nap risk |
|---|---|---|---|
| `keepaliveTimer` (`startKeepalive`) | **15 s** | **only while PAUSED** | **critical** |
| `zombieCheckTimer` (`startZombieCheck`) | 30 s | only while actively recording | moderate |

The keepalive fires every 15 s against Soniox's **~20 s** server-side idle
timeout — a margin of only ~5 s. It runs **exclusively during a pause**, which
is precisely when there is **no audio I/O** (the mic tap / Core Audio IOProc is
paused), so nothing keeps the app active and App Nap is free to engage. If the
window is also backgrounded/occluded, the 15 s timer slips past 20 s, Soniox
drops the socket, and:

- the zombie timer that might notice is deliberately **off** during a pause;
- `keepalive()`'s own dead-socket detection only runs *when the napped timer
  fires*, so it too is deferred;
- **this target has no reconnection.**

The death goes unnoticed until the user resumes: `resume()` sees
`needsReconnect == true` and calls `failSession(…)`, killing the live session.
The transcript is kept, but recording can't continue — purely because a 15 s
main-run-loop timer was throttled past a 20 s server limit.

An **actively recording** session is far more robust: the keepalive isn't
running (streamed audio frames themselves keep the socket warm), the running
audio hardware I/O suppresses App Nap, and zombie detection has an independent,
non-throttleable path via `reportAudioLevel()` on the audio render thread. But
an occluded window during active recording can still throttle the 30 s zombie
timer (delaying — not causing — detection of a half-open socket).

### Prior state

A repo-wide search found **no** App Nap / power-assertion / background-activity
mitigation anywhere in `OgmoMac` (no `ProcessInfo.beginActivity`, no
`NSAppSleepDisabled`, no power assertion). The only related hits were the iOS
target's `UIBackgroundModes = audio`, which is a UIKit-only concept with no
macOS equivalent — the iOS survival mechanism (audio background mode + an active
`AVAudioSession`) does not transfer to the Mac.

## Decision

Hold an `NSProcessInfo` **activity assertion** for the entire duration of a live
session — recording **or** paused — so recording keeps running when the Mac
would otherwise nap or idle-sleep.

```swift
ProcessInfo.processInfo.beginActivity(
    options: .userInitiated,
    reason: "Live transcription in progress"
)
```

`.userInitiated` both suppresses App Nap **and** disables idle system sleep, so a
live session survives a backgrounded/occluded window *and* keeps recording when
the user steps away (see the option rationale below).

### Where: `LiveSessionStore`, driven by observation

The assertion is owned by `LiveSessionStore` — the `@Observable @MainActor`
singleton that is the **sole** owner of the live session view model and the one
piece of state that deliberately **outlives the window** (so a session keeps
running with the window closed). Two reasons this is the right home rather than
`MacTranscriptionViewModel`:

1. **State-driven, not placement-driven.** `LiveSessionStore` already observes
   the VM's `isRunning`/`isPaused` via `armStatusMirroring` (the observation
   kill-switch pattern). We reuse that loop to acquire/release the assertion
   whenever the session enters or leaves `running || paused`. This is
   automatically correct across *every* teardown path — `stop`, `discard`,
   `failSession`, and even `start()`'s connect-failure catch (which returns
   *without* calling `failSession`) — because they all flip `isRunning`/
   `isPaused` to false. No per-method placement to keep in sync as the VM grows.
2. **File-length budget.** `MacTranscriptionViewModel.swift` sits at 249/250
   code lines (the CI limit). Adding a stored token + acquire/release calls
   there would break the limit; `LiveSessionStore` had ample room.

`updateBackgroundActivity()` is idempotent (acquire only if not held; release
only if held) and is called from (a) the observation loop on every
`isRunning`/`isPaused` change and (b) `clearSession()` as a synchronous
belt-and-suspenders release when the VM is dropped.

**Held across pause/resume:** `pause()`/`resume()` never touch the assertion —
holding it *through* the pause is the entire point, since that's the window
where audio I/O stops and the keepalive timer would otherwise be napped.

**Released on `failSession`:** `failSession` keeps the VM + transcript alive but
truly stops recording (socket closed, no timers left running), so the assertion
is released the instant `isRunning`/`isPaused` go false — a failed-but-unsaved
session doesn't hold the assertion while the user decides whether to save.

### Why `.userInitiated`

`NSActivityOptions` bundles several behaviours. The `userInitiated*` variants
suppress App Nap (and automatic/sudden termination); the difference is idle
**system sleep**:

- `.userInitiated` — suppresses App Nap **and disables idle system sleep**
  (keeps the *system* awake; the **display can still turn off**).
- `.userInitiatedAllowingIdleSystemSleep` — suppresses App Nap but **still lets
  the Mac idle-sleep**.

We chose `.userInitiated`. Issue #174's headline is App Nap, but the product
requirement is broader: **a recording must keep transcribing when the Mac would
otherwise go idle**, not just when a window is occluded. `.userInitiated` covers
both — App Nap suppression fixes the occluded-window stall, and disabling idle
system sleep keeps the capture pipeline + WebSocket alive when the user walks
away (no keyboard/mouse activity), instead of the Mac idle-sleeping and killing
the session.

Notes on scope and cost:

- **A sleeping Mac cannot transcribe.** During real system sleep the CPU is
  halted and audio I/O + networking stop, so no app can record "while asleep."
  The achievable behaviour — and what this delivers — is *preventing* idle sleep
  so the recording continues; it is not recording through sleep.
- **The display still sleeps.** We deliberately do **not** add
  `.idleDisplaySleepDisabled`; the screen turns off on its normal schedule while
  the *system* stays awake and keeps recording. Keeping the screen lit would be
  an unnecessary battery cost.
- **Lid close (clamshell sleep) is not overridden.** On a laptop, closing the
  lid on battery forces sleep regardless of any `NSActivity` assertion, which
  ends the recording. Preventing that is out of scope here (it needs clamshell
  mode — external power + display).
- **Battery.** Holding a system-sleep assertion for an active recording is the
  expected behaviour for capture apps (QuickTime, GarageBand, etc. do the same
  while recording) and only lasts as long as a session is live/paused; it is
  released the instant the session ends.

## Recovery if a stall still happens

The assertion is the primary fix; the existing failure handling is the safety
net. If a socket dies anyway (e.g. a genuine network drop), OgmoMac's recovery
is **not** reconnection — it never had one on this target — but a *graceful*
`failSession`: the disconnect surfaces via the `receiveLoop`/zombie path →
`signalDisconnect()` → `onConnectionStateChange(.disconnected)` →
`failSession(…)`, which stops capture, closes the socket, and **keeps the
transcript** so Stop & Save still persists what was captured. Confirmed the
socket-death → `needsReconnect` → `resume()` → `failSession` path still works
unchanged; the assertion just makes it far less likely to be triggered by a
napped timer rather than a real drop.

## Verification

App Nap only engages on a real (non-debugger-attached, backgrounded/occluded)
run, so this must be checked on a device build, not the debugger:

1. Start a recording, then **pause** it.
2. Fully occlude the Ogmo window (another app full-screen over it) and switch
   focus away for several minutes.
3. Resume — the session should continue rather than fail with "Connection lost
   while paused."
4. **Unattended idle test:** start a recording and leave the Mac completely
   untouched (no keyboard/mouse) past its idle-sleep timer. The screen should
   turn off, but recording should continue (the system stays awake) rather than
   the session ending.
5. Confirm with `pmset -g assertions` while a session is live/paused: Ogmo holds
   a `PreventUserIdleSystemSleep` assertion and shows *not* napping. Both clear
   once the session ends.
6. Confirm the assertion is released after Stop & Save / Discard / a failed
   session (`pmset -g assertions` no longer lists Ogmo) — no lingering assertion.

## Trade-offs and follow-ups

- **Lid-close still sleeps a laptop.** `.userInitiated` prevents *idle* system
  sleep but not clamshell sleep — closing the lid on battery sleeps the Mac and
  ends the recording. Overriding that needs clamshell mode (external power +
  display) and is out of scope.
- **Battery.** Preventing idle system sleep keeps the Mac awake for the whole
  session; this is the standard behaviour for capture apps and is released the
  moment the session ends, but a very long unattended recording will draw power
  it otherwise wouldn't. If this becomes a concern, a user setting ("keep Mac
  awake while recording", defaulting on) could gate between `.userInitiated` and
  `.userInitiatedAllowingIdleSystemSleep`.
- If OgmoMac later gains a background-safe reconnection path, the assertion and
  the graceful-fail behaviour remain complementary.
