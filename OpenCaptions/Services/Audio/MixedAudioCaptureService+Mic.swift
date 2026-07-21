//
//  MixedAudioCaptureService+Mic.swift
//  OpenCaptions
//
//  The microphone half of the mixed source — a PLAIN (non-VPIO) AVAudioEngine
//  input tap, identical in spirit to MacAudioService. We deliberately do NOT use
//  voice-processing I/O: on macOS VPIO reconfigures the shared input device
//  (perturbing other apps' mic access) and fires an AVAudioEngineConfiguration
//  change on teardown that aborts a live source swap. Echo
//  cancellation of the system audio's speaker-bleed is handled in software here
//  (`OpenCaptionsAEC`). The tap is the mix pacer: per callback it extracts
//  channel 0, resamples to 16 kHz mono, pulls a matching span of system audio
//  from the ring, runs the canceller (mic ← AEC(mic, reference: system)), adds
//  the clean system audio back, and yields. Split from the lifecycle file to stay
//  under the line limit.
//

import AVFoundation
import Foundation
import OSLog

extension MixedAudioCaptureService {

    // MARK: - Engine lifecycle

    /// Install the mic tap and start the engine. Throws if the engine refuses to
    /// start (no input device, etc.). Deliberately a PLAIN engine — no voice
    /// processing (see the file header): VPIO on macOS seizes the
    /// shared input device and breaks both mic coexistence and live switching.
    func configureMicEngine() throws {
        let input = micEngine.inputNode

        // Build the echo canceller before the tap so the first mic frame already
        // has it — but ONLY when the remote `Mac_aec_enabled` flag is on (default
        // on; snapshotted into `aecEnabled` by `observeAECFlag` before start()).
        // Flag off, or a nil OpenCaptionsAEC, leaves `aec == nil` → the mix falls back to
        // a plain (uncancelled) sum, giving us a Firestore escape hatch if the
        // canceller regresses in the field. Delay 0 — the ring already
        // hands the tap an aligned system span (tune on device if echo leaks; see
        // OpenCaptionsAEC.setStreamDelayMs).
        aecLock.lock()
        let shouldBuildAEC = aecEnabled
        aecLock.unlock()
        if shouldBuildAEC, let canceller = OpenCaptionsAEC(sampleRate: 16_000, channels: 1) {
            canceller.setStreamDelayMs(0)
            aecLock.lock()
            // A flag flip-off may have raced in during construction (setAECEnabled
            // ran on the main actor); only keep the canceller if still enabled, else
            // drop it here (no tap installed yet, so no render callback touches it).
            if aecEnabled { aec = canceller }
            aecLock.unlock()
            log.notice("OpenCaptionsAEC ready — mixed-source echo cancellation engaged")
        } else if shouldBuildAEC {
            log.error("OpenCaptionsAEC init failed — mix uncancelled (plain sum)")
        } else {
            log.notice("OpenCaptionsAEC disabled by feature flag — mix uncancelled (plain sum)")
        }

        // Read the live hardware input format and install the tap with it (mirrors
        // MacAudioService). A multi-channel input is handled at mix time by
        // extracting channel 0 in `downmixChannelZeroTo16k`.
        let tapFormat = input.inputFormat(forBus: 0)

        // A not-yet-provisioned input device reports a 0-channel / 0-Hz format;
        // installing a tap with it trips AVAudioEngine's "required condition is
        // false" abort. Fail the session gracefully instead (the caller's
        // teardownAll() releases the AEC allocated just above).
        guard tapFormat.channelCount > 0, tapFormat.sampleRate > 0 else {
            throw NSError(domain: "MixedAudio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone input unavailable"])
        }

        input.installTap(onBus: 0, bufferSize: 0, format: tapFormat) { [weak self] buffer, time in
            self?.handleMicBuffer(buffer, at: time)
        }

        micEngine.prepare()
        try micEngine.start()

        // Registered AFTER start() (like MacAudioService) so the initial setup
        // doesn't trip it; a later device/route change silences the tap → the
        // owner fails the session (keeping the transcript).
        micConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: micEngine, queue: .main
        ) { [weak self] _ in
            self?.onInterruption?()
        }
    }

    /// Stop mic capture and release its resources (safe to call once from stop()).
    func teardownMic() {
        if let observer = micConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            micConfigObserver = nil
        }
        micEngine.inputNode.removeTap(onBus: 0)
        if micEngine.isRunning { micEngine.stop() }
        micConverter = nil
        micSourceFormat = nil
        // Frees the Speex states. The tap is gone so no render callback races it,
        // but take `aecLock` anyway to keep every `aec` access uniformly guarded.
        aecLock.lock(); aec = nil; aecLock.unlock()
    }

    // MARK: - Tap → mix

    /// Convert a mic buffer to 16 kHz mono (channel 0), cancel the system audio's
    /// echo out of it, sum the clean system audio back, and yield the mixed frame.
    /// Runs on the audio render thread (the only thread that touches `aec`).
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let continuation, let mono = downmixChannelZeroTo16k(buffer),
              let micPtr = mono.floatChannelData?.pointee else { return }
        let n = Int(mono.frameLength)
        guard n > 0 else { return }

        // Snapshot the canceller under the lock, holding a strong local ref for the
        // duration of the process calls below. A concurrent mid-session release
        // (main-actor `setAECEnabled(false)` nils `aec`) then can't deallocate it
        // out from under us — the object outlives `canceller`, and OpenCaptionsAEC's
        // "single thread drives process/processReverse" rule still holds (only this
        // render thread ever calls them). Nil → plain sum (flag off or init failed).
        aecLock.lock()
        let canceller = aec
        aecLock.unlock()

        // Pull an n-sample span of system audio (zero-padded on shortfall). It's
        // both the far-end REFERENCE for echo cancellation and the clean audio we
        // re-add so remote participants stay in the transcript.
        if mixScratch.count < n { mixScratch = [Float](repeating: 0, count: n) }

        // Pin the system audio's latency: trim the ring to just this read's span
        // plus a small jitter cushion BEFORE reading, so the reference and the
        // re-added system span track the fresh mic instead of lagging by the startup
        // seed. This is what collapses the mic-leads-system gap and moves the AEC
        // far-end reference into the canceller's causal window. The
        // returned pre-trim occupancy feeds the on-device alignment log.
        let occupancyBeforeTrim = systemRing.trim(
            toMaxAvailable: n + Self.systemRefCushionSamples)
        var samplesRead = 0
        mixScratch.withUnsafeMutableBufferPointer { scratch in
            for i in 0..<n { scratch[i] = 0 }
            samplesRead = systemRing.read(into: scratch, count: n)
            guard let systemRef = scratch.baseAddress else { return }

            // Strip the system audio's speaker-bleed out of the mic (built-in
            // speakers; headphones have none). `process` writes the cleaned mic in
            // place. Skipped → plain sum → if the canceller is off/failed to init.
            if let canceller {
                canceller.processReverse(systemRef, frameCount: Int32(n))
                canceller.process(micPtr, into: micPtr, frameCount: Int32(n))
            }

            // mixed = cleaned mic (user, echo removed) + system (remote), clamped
            // to avoid wrap distortion.
            for i in 0..<n {
                micPtr[i] = max(-1.0, min(1.0, micPtr[i] + scratch[i]))
            }
        }
        recordMixStats(n: n, read: samplesRead, occupancy: occupancyBeforeTrim)
        continuation.yield(AudioFrame(buffer: mono, timestamp: time))
    }

    /// Extract channel 0 of a (possibly multi-channel) mic buffer and resample it
    /// to the shared 16 kHz mono target with a reused converter (rebuilt if the
    /// device rate changes). Returns an OWNED buffer safe to hand off.
    private func downmixChannelZeroTo16k(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outputFormat, let source = buffer.floatChannelData?.pointee,
              buffer.frameLength > 0 else { return nil }
        let sourceRate = buffer.format.sampleRate
        guard sourceRate > 0 else { return nil }

        // (Re)build the mono source format + converter for this device rate.
        if micSourceFormat?.sampleRate != sourceRate {
            micSourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)
            micConverter = nil
        }
        guard let sourceFormat = micSourceFormat else { return nil }
        if micConverter == nil {
            micConverter = AVAudioConverter(from: sourceFormat, to: outputFormat)
        }
        guard let converter = micConverter else { return nil }

        let frames = buffer.frameLength
        guard let monoIn = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              let monoInPtr = monoIn.floatChannelData?.pointee else { return nil }
        monoIn.frameLength = frames
        memcpy(monoInPtr, source, Int(frames) * MemoryLayout<Float>.size)

        let ratio = outputFormat.sampleRate / sourceRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16   // +resampler slack
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return monoIn
        }
        var conversionError: NSError?
        let result = autoreleasepool {
            converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
        }
        guard conversionError == nil, result != .error, outBuffer.frameLength > 0 else { return nil }
        return outBuffer
    }
}
