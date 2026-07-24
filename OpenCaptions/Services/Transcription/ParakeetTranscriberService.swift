//
//  ParakeetTranscriberService.swift
//  OpenCaptions
//
//  On-device (offline) speech-to-text via NVIDIA Parakeet TDT v2 (parakeet-tdt-0.6b-v2 — the
//  highest-accuracy English model), driven in real time by FluidAudio's `SlidingWindowAsrManager`.
//  Conforms to `RealtimeTranscriptionEngine` so it is interchangeable with cloud Soniox and the
//  Nemotron engine behind `MacTranscriptionViewModel`.
//
//  TDT v2 is an offline batch transducer; `SlidingWindowAsrManager` makes it stream by re-encoding
//  an overlapping window (cadence set by `ParakeetEngineConfig.responsiveStreaming.chunkSeconds`)
//  and exposing a two-tier confirmed/volatile transcript (like Apple's SpeechAnalyzer). Audio never
//  leaves the device and there is no socket. English only; no diarization.
//
//  Update mapping: we reconstruct the manager's confirmed/volatile state from its update stream
//  (`text` + `isConfirmed`), emit each newly-confirmed suffix as a final (the ViewModel flushes it
//  into a bubble on TDT v2's native punctuation) and the current volatile as the live partial. If
//  the built-in sliding-window latency/quality proves inadequate, swap this file's internals for a
//  VoiceInk-style LocalAgreement engine behind the same protocol (see the decision doc).
//

import AVFoundation
import FluidAudio
import Foundation

final class ParakeetTranscriberService: RealtimeTranscriptionEngine {

    // MARK: - Engine Capabilities

    /// On-device traits: no diarization, no reliable per-token clock (the ViewModel stamps from
    /// its own clock), no endpoint tokens (the ViewModel flushes on TDT v2's native punctuation),
    /// and `maxSessionSeconds = .infinity` so the ViewModel never hot-swaps us — a reset would
    /// reload the CoreML model and discard streaming state.
    let capabilities = EngineCapabilities(
        engineId: "parakeet",
        displayName: "Parakeet TDT v2",
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

    // On-device: there is no connection to die, so we never request a reconnect.
    let needsReconnect = false

    // MARK: - Configuration

    let config: ParakeetEngineConfig

    init(config: ParakeetEngineConfig) {
        self.config = config
    }

    // MARK: - Private

    private var manager: SlidingWindowAsrManager?
    private var feedContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?

    /// Two-tier transcript state reconstructed from the update stream, mirroring the manager's own
    /// `confirmedTranscript`/`volatileTranscript`. Mutated only inside the single serial updates
    /// loop, so no locking is needed. `emittedConfirmed` marks what we've already emitted as finals.
    private var confirmed = ""
    private var volatileText = ""
    private var emittedConfirmed = ""

    // MARK: - Lifecycle

    /// Loads the downloaded CoreML model and starts the sliding-window recognizer. Throws if the
    /// model isn't downloaded (the user downloads it from Settings → Recording) so we never block
    /// here on a multi-hundred-MB network fetch.
    func connectAndStart() async throws {
        guard FluidAudioModelLoader.isParakeetDownloaded() else {
            let error = TranscriptionServiceError.connectionFailed(underlying: nil)
            onError?(error)
            throw error
        }

        let models: AsrModels
        do {
            models = try await FluidAudioModelLoader.loadParakeetModels()
        } catch {
            onError?(.connectionFailed(underlying: error))
            throw TranscriptionServiceError.connectionFailed(underlying: error)
        }

        confirmed = ""
        volatileText = ""
        emittedConfirmed = ""

        let mgr = SlidingWindowAsrManager(config: config.slidingConfig)
        do {
            // Load the models, then start the background recognizer (which waits on the
            // manager's input stream). `startStreaming` replaces the old combined `start`.
            try await mgr.loadModels(models)
            try await mgr.startStreaming()
        } catch {
            onError?(.connectionFailed(underlying: error))
            throw TranscriptionServiceError.connectionFailed(underlying: error)
        }

        // Obtain the update stream BEFORE feeding audio. Accessing `transcriptionUpdates` sets the
        // manager's continuation synchronously, so no early window update can be dropped.
        let updates = await mgr.transcriptionUpdates
        startUpdatesLoop(updates)

        manager = mgr
        onConnectionStateChange?(.connected)
        startFeedLoop(manager: mgr)
    }

    /// Buffers a chunk of 16 kHz mono Float32 PCM for the serial feed into the manager.
    func sendAudioChunk(_ data: Data) {
        guard let buffer = FluidAudioStreamBridge.makeBuffer(from: data) else { return }
        feedContinuation?.yield(buffer)
    }

    /// End-of-audio. Intentionally a no-op: `MacTranscriptionViewModel.stop()` flushes the current
    /// partial line (our volatile tail) into a final line before teardown.
    func finalize() {}

    func close() {
        feedContinuation?.finish()
        feedContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        // `cancel()` ends the recognizer without a (blocking) final flush; the ViewModel already
        // saved the trailing volatile as a final line before calling close().
        if let mgr = manager { Task { await mgr.cancel() } }
        manager = nil
    }

    deinit {
        feedContinuation?.finish()
        feedTask?.cancel()
        updatesTask?.cancel()
    }

    // MARK: - Connection health (on-device no-ops)

    func startKeepalive() {}
    func stopKeepalive() {}
    func startZombieCheck() {}
    func stopZombieCheck() {}
    func reportAudioLevel(_ level: Float) {}
    func markTokensReceived() {}

    // MARK: - Feed Loop

    /// Drains buffered audio into the manager serially (in-order feeding). Strongly captures the
    /// manager so it lives until the stream finishes.
    private func startFeedLoop(manager: SlidingWindowAsrManager) {
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.feedContinuation = continuation
        }
        feedTask = Task.detached(priority: .userInitiated) {
            for await buffer in stream {
                await manager.streamAudio(buffer)
            }
        }
    }

    // MARK: - Update Loop

    private func startUpdatesLoop(_ updates: AsyncStream<SlidingWindowTranscriptionUpdate>) {
        updatesTask = Task { [weak self] in
            for await update in updates {
                self?.handle(update)
            }
        }
    }

    /// Reconstructs the manager's confirmed/volatile two-tier state from each update (mirrors its
    /// internal `updateTranscriptionState`), then emits the newly-confirmed suffix as a final and
    /// the current volatile as the live partial.
    private func handle(_ update: SlidingWindowTranscriptionUpdate) {
        if update.isConfirmed {
            if !volatileText.isEmpty {
                confirmed = confirmed.isEmpty ? volatileText : confirmed + " " + volatileText
            }
            volatileText = update.text
        } else {
            volatileText = update.text
        }

        var finals: [TranscriptionToken] = []
        if confirmed.count > emittedConfirmed.count, confirmed.hasPrefix(emittedConfirmed) {
            let newlyConfirmed = String(confirmed.dropFirst(emittedConfirmed.count))
            if !newlyConfirmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finals.append(FluidAudioStreamBridge.token(text: newlyConfirmed, isFinal: true))
            }
            emittedConfirmed = confirmed
        }

        let partials = volatileText.isEmpty
            ? [] : [FluidAudioStreamBridge.token(text: volatileText, isFinal: false)]
        guard !finals.isEmpty || !partials.isEmpty else { return }
        onTokens?(finals, partials)
    }
}
