//
//  MacAudioService.swift
//  OpenCaptions
//
//  Microphone capture for macOS. Reuses the proven iOS DSP pipeline
//  (AVAudioEngine input tap → AVAudioConverter → 16 kHz mono Float32),
//  but with NO AVAudioSession (macOS has none): the device input format is
//  read dynamically and resampled by the converter. Mic access goes through
//  AVCaptureDevice's TCC prompt.
//

import AppKit
import AVFoundation
import Foundation

/// Captures microphone audio on macOS and exposes 16 kHz / mono / Float32
/// frames as an `AsyncStream`. Conforms to `AudioCaptureSource` so it is
/// interchangeable with the system-audio source (`AudioFrame` lives there).
final class MacAudioService: AudioCaptureSource {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var isRunning = false
    private var isPaused = false

    /// Fired when the engine's configuration changes mid-capture (input device
    /// unplugged/switched, sample-rate change). The installed tap stops
    /// delivering buffers when this happens, so the owner must tear down.
    var onInterruption: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    /// Requests microphone access via TCC. Returns `true` if granted.
    static func requestMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// The current mic TCC status WITHOUT prompting — lets onboarding pre-fill the
    /// "granted" state on appear and pick a "denied" vs "not yet asked" affordance.
    static var micAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Convenience: whether the mic is already authorized (no prompt).
    static var isMicAuthorized: Bool { micAuthorization == .authorized }

    /// Opens System Settings › Privacy & Security › Microphone, for the
    /// denied-permission recovery path (mirrors `MacAudioPermissionView`).
    static func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Start capturing and return an async stream of frames. `async` to satisfy
    /// the `AudioCaptureSource` contract (the body remains synchronous).
    func start() async throws -> AsyncStream<AudioFrame> {
        guard !isRunning else { return makeStream() }
        try configureEngineAndTap()
        isRunning = true
        return makeStream()
    }

    /// Stop capturing and release audio resources.
    func stop() {
        guard isRunning else { return }
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
        outFormat = nil
        isRunning = false
        isPaused = false
    }

    /// Soft-pause capture: stop the engine rendering but KEEP the tap installed
    /// so the `AsyncStream` stays open (no `finish()`). macOS has no
    /// `AVAudioSession`, so unlike iOS there is nothing to deactivate.
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        if engine.isRunning { engine.pause() }
    }

    /// Resume capture after `pause()`. Throwing so the owner can fail the
    /// session if the engine refuses to restart (e.g. input device vanished).
    func resume() throws {
        guard isRunning, isPaused else { return }
        isPaused = false
        if !engine.isRunning { try engine.start() }
    }

    deinit { stop() }

    // MARK: - Private

    private func makeStream() -> AsyncStream<AudioFrame> {
        AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(8)) { [weak self] cont in
            self?.continuation = cont
        }
    }

    /// Install a tap on the input node and convert whatever the device delivers
    /// to our unified 16 kHz / mono / Float32 target.
    private func configureEngineAndTap() throws {
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)

        // A not-yet-provisioned input device reports a 0-channel / 0-Hz format
        // (e.g. a first-launch HAL race where requestAccess returns before the
        // device is ready). Feeding that to AVAudioConverter/installTap trips
        // AVAudioEngine's "required condition is false" abort, so fail the
        // session gracefully instead of crashing.
        guard inFmt.channelCount > 0, inFmt.sampleRate > 0 else {
            throw NSError(domain: "MacAudio", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone input unavailable"])
        }

        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "MacAudio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to create output format"])
        }
        outFormat = outFmt

        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw NSError(domain: "MacAudio", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to create audio converter"])
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 0, format: inFmt) { [weak self] buf, time in
            guard let self, let converter = self.converter, let outFormat = self.outFormat else { return }

            let ratio = outFormat.sampleRate / buf.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio + 1)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

            var err: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buf
            }
            let status = converter.convert(to: outBuf, error: &err, withInputFrom: inputBlock)
            guard err == nil, status != .error, outBuf.frameLength > 0 else { return }

            _ = self.continuation?.yield(AudioFrame(buffer: outBuf, timestamp: time))
        }

        engine.prepare()
        try engine.start()

        // Registered AFTER start() so the initial engine setup doesn't trip it.
        // A later change (device unplugged, default input switched, sample-rate
        // change) silences this tap, so notify the owner to stop/restart.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onInterruption?()
        }
    }
}
