//
//  SystemAudioTapCaptureService.swift
//  OgmoMac
//
//  Captures system / other-app audio via a Core Audio PROCESS TAP and exposes it
//  as the unified 16 kHz / mono / Float32 `AudioFrame` stream (identical contract
//  to the mic path), so it drops straight into `MacTranscriptionViewModel`.
//
//  Replaces the earlier ScreenCaptureKit source (#205): a process tap uses the
//  narrow "Audio Recording" TCC grant (`NSAudioCaptureUsageDescription`), NOT the
//  full Screen Recording grant. It also doesn't touch the microphone, so it runs
//  alongside a plain mic `AVAudioEngine`. There is no public preflight API — the
//  OS shows the prompt on the first `AudioDeviceStart`, so callers start
//  optimistically. Soft `pause()` gates frame delivery with a flag (no device
//  pause). The tap→aggregate→IOProc wiring lives in `+IO`; device-change
//  interruption in `+Listeners`. Requires macOS 14.4+.
//

import AVFoundation
import CoreAudio
import Foundation
import OSLog

final class SystemAudioTapCaptureService: AudioCaptureSource {

    // MARK: - Shared state (also read by the +IO / +Listeners extensions)

    /// The unified target the pipeline expects.
    let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )
    /// Reused sample-rate / downmix converter (rebuilt if the source format changes).
    var converter: AVAudioConverter?
    /// The format used to wrap each no-copy `AudioBufferList`: the tap's channel
    /// layout / flags with the sample rate corrected to the AGGREGATE's delivered
    /// rate (its main-sub-device/output clock), not the tap's own native rate (#304).
    var sourceFormat: AVAudioFormat?
    /// When true the IOProc early-returns before any conversion — our soft pause.
    var isPaused = false
    var continuation: AsyncStream<AudioFrame>.Continuation?
    var onInterruption: (() -> Void)?

    let log = Logger(subsystem: "com.muhammadramdan.OgmoMac", category: "SystemAudioTap")

    // MARK: - Core Audio objects

    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var ioProcID: AudioDeviceIOProcID?
    let ioQueue = DispatchQueue(label: "com.ogmo.system-audio-tap", qos: .userInteractive)
    /// Retained so it can be removed on teardown (the API keys removal on the block).
    var outputDeviceListener: AudioObjectPropertyListenerBlock?

    // MARK: - Private state

    private var isRunning = false
    /// Set by `stop()` even before `isRunning` flips, and re-checked in `start()`
    /// after the (async) build, so a stop racing startup still tears the tap down.
    private var stopRequested = false
    /// Guards `teardown()` so the blocking Core Audio teardown runs at most once
    /// (single-use source; `deinit { stop() }` must not re-destroy objects).
    private var isTornDown = false

    // MARK: - AudioCaptureSource

    func start() async throws -> AsyncStream<AudioFrame> {
        guard !isRunning else { return makeStream() }
        stopRequested = false
        try buildAndStart()   // +IO: tap + aggregate + IOProc + AudioDeviceStart
        // A stop() may have raced in while we were building; if so, tear the
        // just-started capture down and hand back an already-finished stream.
        if stopRequested {
            teardown()
            return Self.finishedStream()
        }
        installOutputDeviceListener()   // +Listeners
        isRunning = true
        return makeStream()
    }

    func stop() {
        stopRequested = true
        isRunning = false
        isPaused = false
        continuation?.finish()
        continuation = nil
        teardown()
    }

    /// Soft-pause: keep the tap running but drop frames (the socket is held open
    /// by the view model's keepalive), so resume incurs no restart latency.
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
    }

    func resume() throws {
        guard isRunning, isPaused else { return }
        isPaused = false
    }

    deinit { stop() }

    // MARK: - Stream

    func makeStream() -> AsyncStream<AudioFrame> {
        AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(32)) { [weak self] cont in
            self?.continuation = cont
        }
    }

    /// An already-finished stream handed back when a stop() raced startup, so the
    /// consumer's `for await` exits immediately and closes the socket.
    static func finishedStream() -> AsyncStream<AudioFrame> {
        AsyncStream<AudioFrame> { $0.finish() }
    }

    // MARK: - Teardown

    /// Stop + destroy in the required order (device → IOProc → aggregate → tap),
    /// exactly once per instance. Safe before `start()` ever completed.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        removeOutputDeviceListener()   // +Listeners
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        sourceFormat = nil
    }
}
