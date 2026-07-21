//
//  NemotronTranscriberService.swift
//  OpenCaptions
//
//  On-device (offline) speech-to-text via NVIDIA Nemotron Speech Streaming (560 ms), run
//  through FluidAudio's `NemotronStreamingAsrManager`. Conforms to `RealtimeTranscriptionEngine`
//  so it is interchangeable with cloud Soniox behind `MacTranscriptionViewModel`.
//
//  Ported from the iOS `unmute/Services/NemotronTranscriberService.swift`. Audio never leaves
//  the device and there is no socket. Nemotron emits punctuation and capitalization natively
//  (and exposes no end-of-utterance signal), so this engine promotes each completed sentence to
//  a final (the ViewModel flushes it into a bubble on punctuation) and shows the in-progress
//  remainder as a live partial. English only; no diarization.
//

import AVFoundation
import FluidAudio
import Foundation

final class NemotronTranscriberService: RealtimeTranscriptionEngine {

    // MARK: - Engine Capabilities

    /// On-device traits: no diarization, no reliable per-token clock (the ViewModel stamps from
    /// its own clock), no endpoint tokens (the ViewModel flushes on Nemotron's native
    /// punctuation), and `maxSessionSeconds = .infinity` so the ViewModel never hot-swaps us — a
    /// reset would reload the CoreML model and discard streaming state.
    let capabilities = EngineCapabilities(
        engineId: "nemotron",
        displayName: "Nemotron 560ms",
        supportsDiarization: false,
        providesReliableTimestamps: false,
        emitsEndpointTokens: false,
        maxSessionSeconds: .infinity,
        requiresPreparation: true  // loads the CoreML model on first session
    )

    // MARK: - Callbacks

    var onTokens: ((_ finals: [TranscriptionToken], _ partial: [TranscriptionToken]) -> Void)?
    var onError: ((TranscriptionServiceError) -> Void)?
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    // On-device: there is no connection to die, so we never request a reconnect (which would
    // rebuild the engine and reload the model).
    let needsReconnect = false

    // MARK: - Configuration

    let config: NemotronEngineConfig

    init(config: NemotronEngineConfig) {
        self.config = config
    }

    // MARK: - Private

    private var manager: NemotronStreamingAsrManager?
    private var feedContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?

    /// The full transcript already emitted to the ViewModel (through the last completed sentence).
    /// Mutated only inside FluidAudio's partial callback, which the actor invokes serially.
    private var confirmedPrefix = ""

    // MARK: - Lifecycle

    /// Loads the downloaded CoreML model and starts the audio feed. Throws if the model isn't
    /// downloaded (the user downloads it from Settings → Recording) so we never block here on a
    /// multi-hundred-MB network fetch.
    func connectAndStart() async throws {
        guard FluidAudioModelLoader.isNemotronDownloaded(),
            let dir = FluidAudioModelLoader.nemotronModelDir()
        else {
            let error = TranscriptionServiceError.connectionFailed(underlying: nil)
            onError?(error)
            throw error
        }

        let mgr = NemotronStreamingAsrManager(requestedChunkSize: config.chunkSize)
        do {
            try await mgr.loadModels(modelDir: dir)
        } catch {
            onError?(.connectionFailed(underlying: error))
            throw TranscriptionServiceError.connectionFailed(underlying: error)
        }

        confirmedPrefix = ""
        await mgr.setPartialCallback { [weak self] full in self?.handlePartial(full) }

        manager = mgr
        onConnectionStateChange?(.connected)
        startFeedLoop(manager: mgr)
    }

    /// Buffers a chunk of 16 kHz mono Float32 PCM for the serial transcription feed.
    func sendAudioChunk(_ data: Data) {
        guard let buffer = FluidAudioStreamBridge.makeBuffer(from: data) else { return }
        feedContinuation?.yield(buffer)
    }

    /// End-of-audio. Intentionally a no-op: `MacTranscriptionViewModel.stop()` flushes the
    /// current partial line (our in-progress sentence tail) into a final line before teardown.
    func finalize() {}

    func close() {
        feedContinuation?.finish()
        feedContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        // Drop the model reference; the feed loop's strong capture is released when the stream ends.
        manager = nil
    }

    deinit {
        feedContinuation?.finish()
        feedTask?.cancel()
    }

    // MARK: - Connection health (on-device no-ops)

    func startKeepalive() {}
    func stopKeepalive() {}
    func startZombieCheck() {}
    func stopZombieCheck() {}
    func reportAudioLevel(_ level: Float) {}
    func markTokensReceived() {}

    // MARK: - Feed Loop

    /// Drains buffered audio through the manager serially (FluidAudio requires in-order
    /// `process` calls). Strongly captures the manager so it lives until the stream finishes.
    private func startFeedLoop(manager: NemotronStreamingAsrManager) {
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.feedContinuation = continuation
        }
        feedTask = Task.detached(priority: .userInitiated) {
            for await buffer in stream {
                do {
                    _ = try await manager.process(audioBuffer: buffer)
                } catch {
                    print("⚠️ Nemotron process error: \(error)")
                }
            }
        }
    }

    // MARK: - Transcript Bridging

    /// Promotes each completed sentence to a final (the ViewModel flushes it into a bubble on
    /// Nemotron's native punctuation) and shows the in-progress remainder as a live partial. The
    /// shared bridge advances `confirmedPrefix` by exactly what it finalized.
    private func handlePartial(_ full: String) {
        let (finals, partials) = FluidAudioStreamBridge.tokens(
            forFull: full, confirmedPrefix: &confirmedPrefix)
        guard !finals.isEmpty || !partials.isEmpty else { return }
        onTokens?(finals, partials)
    }
}
