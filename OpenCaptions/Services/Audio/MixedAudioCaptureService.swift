//
//  MixedAudioCaptureService.swift
//  OpenCaptions
//
//  macOS audio capture: microphone + system audio MIXED into one 16 kHz / mono /
//  Float32 `AudioFrame` stream so a user on a call is transcribed alongside the
//  other participants.
//
//  Composition: a PLAIN (non-VPIO) mic engine (this file's `+Mic` extension) plus
//  the `SystemAudioTapCaptureService` (Core Audio process tap), reused as-is. Its
//  samples land in a bounded ring buffer; the mic tap is the pacer, pulling a
//  matching span per callback, summing sample-wise, and yielding the mixed frame.
//  System audio is mixed in SOFTWARE only — never routed through the engine's
//  output node (that would replay it to the speakers and double the room audio).
//  Conforms to `AudioCaptureSource`, so it drops straight into the view model.
//
//  Echo note: VPIO was removed because on macOS it seized the
//  shared mic and broke live switching, taking its hardware AEC with it. Echo is
//  now cancelled in SOFTWARE (`OpenCaptionsAEC`, Speex) using the cleanly-captured system
//  audio as the far-end reference, so on built-in speakers the other participants
//  are transcribed once, not doubled. Headphones never had the bleed. The mixer
//  yields `AEC(mic, reference: system) + system` = the user's voice (echo removed)
//  plus the remote audio, each once.
//

import AVFoundation
import Foundation
import OSLog

final class MixedAudioCaptureService: AudioCaptureSource {

    /// Reports whether the software echo canceller came up at session start
    /// (Console.app → subsystem `com.muhammadramdan.OpenCaptions`, category `MixedAudio`),
    /// so "single, clean transcript" can be confirmed as *the AEC engaged* rather
    /// than a silent fall-back to an uncancelled sum.
    let log = Logger(subsystem: "com.muhammadramdan.OpenCaptions", category: "MixedAudio")

    var onInterruption: (() -> Void)?

    // MARK: - System-audio half (Core Audio process tap)

    let system = SystemAudioTapCaptureService()
    var systemDrainTask: Task<Void, Never>?
    /// ~500 ms of 16 kHz system audio; drop-oldest absorbs mic-vs-tap drift. The
    /// mic pacer trims it to a tight `systemRefCushionSamples` bound before each
    /// read; this 500 ms is only the hard safety ceiling.
    let systemRing = AudioRingBuffer(capacity: 8_000)

    /// Steady-state look-behind the mic pacer keeps in `systemRing`: at once the
    /// underrun cushion (absorbs the async drain task's scheduling jitter so a
    /// bursty mic read doesn't zero-pad) and the residual lag of the system audio
    /// behind the mic. Before each read the pacer trims the ring to
    /// `n + this`, so after startup the mic-leads-system gap — and the AEC far-end
    /// reference's lag — collapses from the startup seed (up to the 500 ms ring cap)
    /// to this. 800 = 50 ms: comfortably above a ~10-12 ms aggregate IO block plus
    /// drain jitter, and well inside OpenCaptionsAEC's 200 ms filter tail. Tune DOWN toward
    /// ~480 (30 ms) once the mic tap buffer size and drain jitter are measured on
    /// device (see the `mix align` Console log); raise if the reference goes choppy.
    /// See docs/2026-07-16-macos-mic-system-sync-fix.md.
    static let systemRefCushionSamples = 800

    // MARK: - Mix-alignment instrumentation
    /// Per-callback stats accumulated on the mic render thread (single-threaded, so
    /// unlocked) and flushed to Console (~1 s) so the mic tap buffer size, the
    /// steady-state ring occupancy, and the read-underrun ratio can be measured on
    /// device to tune `systemRefCushionSamples`. See `recordMixStats`.
    var statCallbackCount = 0
    var statSamplesRequested = 0
    var statSamplesRead = 0
    var statOccupancySum = 0
    var statMinN = Int.max
    var statMaxN = 0

    // MARK: - Mic half (plain, non-VPIO) — configured in +Mic

    let micEngine = AVAudioEngine()
    /// 16 kHz mono target shared by the mic converter and the mixed output.
    let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )
    var micConverter: AVAudioConverter?
    /// Cached mono source format (channel-0 extract) at the live device rate;
    /// rebuilt if the rate changes so a stale converter can't crash on a
    /// multi-channel VPIO buffer.
    var micSourceFormat: AVAudioFormat?
    /// Reused scratch for the system span pulled per mic callback. The mic tap is
    /// serial, so a single instance-owned buffer is safe and avoids allocating on
    /// the audio callback path.
    var mixScratch = [Float]()
    var micConfigObserver: NSObjectProtocol?
    /// Software echo canceller: strips the system audio's speaker-bleed out of the
    /// mic (built-in speakers) before the mix. Always built at session start by
    /// `configureMicEngine`; nil (plain sum) only if `OpenCaptionsAEC` fails to init.
    /// `process`/`processReverse` are driven only from the mic render thread
    /// (OpenCaptionsAEC's single-thread rule), but the *reference* to this object is
    /// touched from two threads — the render thread reads it while the (off-main)
    /// setup assigns it and teardown releases it — so every access goes through
    /// `aecLock`.
    var aec: OpenCaptionsAEC?
    /// Serializes access to `aec` across the mic render thread, the (off-main)
    /// `start()` setup that publishes it, and the teardown that releases it. Cheap
    /// and near-always uncontended — mirrors the `NSLock` the render thread already
    /// takes each callback via `AudioRingBuffer`.
    let aecLock = NSLock()

    var continuation: AsyncStream<AudioFrame>.Continuation?
    private var isRunning = false
    /// Set by `stop()` even before `isRunning` flips true, and re-checked in
    /// `start()` after each async step, so a stop() that races the tap's async
    /// startup still tears everything down (mirrors `SystemAudioTapCaptureService`).
    private var stopRequested = false
    /// Guards `teardownAll()` so it does its blocking audio-engine teardown at
    /// most once per instance (this source is single-use — a new one is built
    /// per session/swap). Without it, the always-called `deinit { stop() }` would
    /// re-run `removeTap`/`engine.stop()` AFTER an explicit `stop()` already did.
    /// Because the owning push task (`.userInitiated`) holds the last strong ref
    /// and releases it when it drains, that second teardown would run in `deinit`
    /// ON the user-initiated task thread, synchronously blocking on the engine's
    /// default-QoS internal thread — a priority inversion. Mirrors why
    /// `MacAudioService.stop()`'s `guard isRunning` makes its deinit a no-op.
    private var isTornDown = false

    // MARK: - AudioCaptureSource

    /// Start both halves and return the mixed frame stream. Throws if the system
    /// tap can't start or the mic engine refuses to start (no input device).
    func start() async throws -> AsyncStream<AudioFrame> {
        guard !isRunning else { return makeStream() }
        stopRequested = false
        let stream = makeStream()

        // Start the system tap first (its async setup can throw) and begin
        // draining into the ring, THEN start the mic pacer last so the
        // consumer sees mixed frames the instant the pump spins up (only a tiny,
        // ring-bounded span of system audio buffers ahead of the mic in between).
        system.onInterruption = { [weak self] in self?.onInterruption?() }
        let systemFrames: AsyncStream<AudioFrame>
        do {
            systemFrames = try await system.start()
        } catch {
            teardownAll()
            throw error
        }
        // A stop() may have raced in while the tap was starting; if so, tear the
        // just-started capture down and hand back a finished stream.
        if stopRequested { teardownAll(); return Self.finishedStream() }
        startSystemDrain(systemFrames)

        do {
            try configureMicEngine()   // +Mic: VPIO + tap + engine.start()
        } catch {
            teardownAll()
            throw error
        }
        if stopRequested { teardownAll(); return Self.finishedStream() }

        isRunning = true
        return stream
    }

    func stop() {
        // Record the request even if we're not "running" yet — start()'s async
        // setup checks this so a stop mid-startup still tears the stream down.
        stopRequested = true
        isRunning = false
        teardownAll()
    }

    /// Soft-pause both halves: the mic engine stops rendering (no pacer → no mixed
    /// frames) and the tap drops its frames. The output stream stays open, and the
    /// drain task keeps awaiting — only `stop()` cancels it.
    func pause() {
        guard isRunning else { return }
        if micEngine.isRunning { micEngine.pause() }
        system.pause()
    }

    /// Resume after `pause()`. Throwing so the owner can fail the session if a
    /// half refuses to restart (e.g. input device vanished while paused).
    func resume() throws {
        guard isRunning else { return }
        // Drop system audio buffered before the pause (the tap was paused, so
        // nothing wrote meanwhile) — otherwise the first resumed mic frames would
        // mix in stale, out-of-context audio from before the break.
        systemRing.reset()
        try system.resume()                                // clears the tap's paused flag
        if !micEngine.isRunning { try micEngine.start() }
    }

    deinit { stop() }

    // MARK: - Private

    /// Tear both halves down. Truly idempotent (see `isTornDown`) and safe to call
    /// before `start()` ever completed, so every error / stop / race path — and the
    /// `deinit` safety net — funnels through here while the blocking audio-engine
    /// teardown happens exactly once, on whichever thread reaches it first.
    private func teardownAll() {
        guard !isTornDown else { return }
        isTornDown = true
        teardownMic()
        system.onInterruption = nil
        system.stop()
        systemDrainTask?.cancel(); systemDrainTask = nil
        continuation?.finish(); continuation = nil
        systemRing.reset()
    }

    private func makeStream() -> AsyncStream<AudioFrame> {
        AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(8)) { [weak self] cont in
            self?.continuation = cont
        }
    }

    /// An already-finished stream handed back when a stop() raced startup, so the
    /// consumer's `for await` exits immediately and closes the socket.
    private static func finishedStream() -> AsyncStream<AudioFrame> {
        AsyncStream<AudioFrame> { $0.finish() }
    }

    /// Drains system-tap frames (already 16 kHz mono) into the ring on a background
    /// task. Kept alive across pause/resume; `stop()` cancels it and the tap
    /// finishing the stream ends the loop naturally too.
    private func startSystemDrain(_ frames: AsyncStream<AudioFrame>) {
        systemDrainTask = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                guard let channel = frame.buffer.floatChannelData?.pointee,
                      frame.buffer.frameLength > 0 else { continue }
                self.systemRing.write(UnsafeBufferPointer(
                    start: channel, count: Int(frame.buffer.frameLength)))
            }
        }
    }
}
