//
//  SpeechAnalyzerTranscriberService.swift
//  OpenCaptions
//
//  On-device (offline) speech-to-text via Apple's `Speech` framework `SpeechAnalyzer`/
//  `SpeechTranscriber` (WWDC25, macOS 26+). Conforms to `RealtimeTranscriptionEngine` so it is
//  interchangeable with cloud Soniox and the FluidAudio Nemotron/Parakeet engines behind
//  `MacTranscriptionViewModel`. Audio never leaves the device; English only; no diarization
//  (matching the existing on-device ceiling). See docs/2026-08-12-macos-speechanalyzer-engine.md
//  and the spike doc it references for why the macOS 26.0 availability gate works without a
//  deployment-target bump.
//
//  `SpeechTranscriber.results` reports each FINAL result as its own new segment and each
//  non-final (volatile) result as a REPLACEMENT of the current partial — the same shape as
//  Parakeet's confirmed/volatile handling, unlike Nemotron's full-transcript diffing.
//  `AnalyzerInputConverter` (the obvious auto-converting helper) is macOS 27+, one major version
//  ahead of this whole feature's floor, so audio is hand-converted via a plain `AVAudioConverter`
//  (mirroring `NemotronPostSessionEngine`'s own decode loop) into the analyzer's preferred format
//  before wrapping each buffer in an `AnalyzerInput`.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriberService: RealtimeTranscriptionEngine {

    // MARK: - Engine Capabilities

    /// On-device traits: no diarization, no reliable per-token clock (the ViewModel stamps from
    /// its own clock), no endpoint tokens, and `maxSessionSeconds = .infinity` so the ViewModel
    /// never hot-swaps us — a reset would discard the analyzer's streaming state.
    let capabilities = EngineCapabilities(
        engineId: "appleSpeech",
        displayName: "Apple Speech",
        supportsDiarization: false,
        providesReliableTimestamps: false,
        emitsEndpointTokens: false,
        maxSessionSeconds: .infinity,
        requiresPreparation: true  // asks the analyzer to prepare its model on first session
    )

    // MARK: - Callbacks

    var onTokens: ((_ finals: [TranscriptionToken], _ partial: [TranscriptionToken]) -> Void)?
    var onError: ((TranscriptionServiceError) -> Void)?
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    // On-device: there is no connection to die, so we never request a reconnect.
    let needsReconnect = false

    // MARK: - Configuration

    private static let locale = Locale(identifier: "en-US")

    // MARK: - Private

    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var runTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Prepares the analyzer/transcriber and starts feeding an audio input sequence. Throws if
    /// the on-device asset isn't installed yet (the user downloads it from Settings → General),
    /// mirroring the FluidAudio engines' "check, don't download on demand" contract.
    func connectAndStart() async throws {
        guard await AppleSpeechModelManager.shared.status == .ready else {
            let error = TranscriptionServiceError.connectionFailed(underlying: nil)
            onError?(error)
            throw error
        }

        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) ?? Self.locale
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else {
            let error = TranscriptionServiceError.connectionFailed(underlying: nil)
            onError?(error)
            throw error
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            onError?(.connectionFailed(underlying: error))
            throw TranscriptionServiceError.connectionFailed(underlying: error)
        }

        self.analyzer = analyzer
        self.analyzerFormat = format
        self.converter = nil  // rebuilt lazily from the first chunk's actual source format

        startResultsLoop(transcriber)

        let stream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                self?.handleAnalyzerFailure(error)
            }
        }

        onConnectionStateChange?(.connected)
    }

    /// Converts a chunk of 16 kHz mono Float32 PCM to the analyzer's preferred format and feeds
    /// it in. `AnalyzerInputConverter` would do this automatically but is macOS 27+ (one version
    /// ahead of this feature's floor), so the conversion is hand-rolled with `AVAudioConverter`.
    func sendAudioChunk(_ data: Data) {
        guard let format = analyzerFormat,
            let sourceBuffer = FluidAudioStreamBridge.makeBuffer(from: data)
        else { return }

        if converter == nil {
            converter = AVAudioConverter(from: sourceBuffer.format, to: format)
        }
        guard let converter else { return }

        let ratio = format.sampleRate / sourceBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity)
        else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        guard conversionError == nil, status != .error, outputBuffer.frameLength > 0 else { return }

        inputContinuation?.yield(AnalyzerInput(buffer: outputBuffer))
    }

    /// End-of-audio. Intentionally a no-op: `MacTranscriptionViewModel.stop()` flushes the
    /// current partial line into a final line before teardown, matching Nemotron/Parakeet.
    func finalize() {}

    func close() {
        inputContinuation?.finish()
        inputContinuation = nil
        runTask?.cancel()
        runTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        // `cancelAndFinishNow()` ends the analyzer without a (blocking) final flush; the
        // ViewModel already saved the trailing volatile as a final line before calling close().
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        converter = nil
        analyzerFormat = nil
    }

    deinit {
        inputContinuation?.finish()
        runTask?.cancel()
        resultsTask?.cancel()
    }

    // MARK: - Connection health (on-device no-ops)

    func startKeepalive() {}
    func stopKeepalive() {}
    func startZombieCheck() {}
    func stopZombieCheck() {}
    func reportAudioLevel(_ level: Float) {}
    func markTokensReceived() {}

    // MARK: - Results Loop

    private func startResultsLoop(_ transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                self?.handleAnalyzerFailure(error)
            }
        }
    }

    /// Each FINAL result is its own new segment (matching Parakeet's confirmed tier); each
    /// non-final (volatile) result REPLACES the current partial — `SpeechTranscriber.Result.text`
    /// is per-result, not the running full-transcript Nemotron reports.
    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.isEmpty else { return }
        let token = FluidAudioStreamBridge.token(text: text, isFinal: result.isFinal)
        if result.isFinal {
            onTokens?([token], [])
        } else {
            onTokens?([], [token])
        }
    }

    private func handleAnalyzerFailure(_ error: Error) {
        onError?(.connectionFailed(underlying: error))
    }
}
