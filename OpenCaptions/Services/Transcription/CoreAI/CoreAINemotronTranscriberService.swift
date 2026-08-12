//
//  CoreAINemotronTranscriberService.swift
//  OpenCaptions
//
//  On-device (offline) speech-to-text via Apple Core AI's Nemotron 3.5 ASR Streaming, loaded
//  through CoreAIPluginLoader (see its header for why this needs a dlopen'd sibling package
//  rather than a normal dependency). Conforms to `RealtimeTranscriptionEngine` so it is
//  interchangeable with Soniox and the FluidAudio on-device engines behind
//  `MacTranscriptionViewModel`. macOS 27+ only — `MacTranscriptionEngineKind.availableCases`
//  hides `.coreAINemotron` everywhere below that.
//
//  Unlike `.coreAIParakeet` (batch/post-session only — Core AI's Parakeet export has no
//  streaming path), this model is genuinely streaming: cache-aware KV/conv state carried across
//  320ms chunks with no fixed encoder bucket, so it's the FIRST Core AI engine reachable from
//  live capture. Audio never leaves the device and there is no socket. English only (see the
//  design doc for why); no diarization; no term biasing. See
//  docs/2026-08-12-macos-coreai-nemotron-streaming.md (issue #55).
//
//  Each `session.feed` call returns the full transcript-so-far, exactly like FluidAudio
//  Nemotron's partial callback, so this reuses `FluidAudioStreamBridge.tokens(forFull:
//  confirmedPrefix:)` for the same sentence/tail segmentation `NemotronTranscriberService` uses
//  — the diffing logic is engine-agnostic.
//

import Foundation

final class CoreAINemotronTranscriberService: RealtimeTranscriptionEngine {

    // MARK: - Engine Capabilities

    /// On-device traits: no diarization, no reliable per-token clock (the ViewModel stamps from
    /// its own clock), no endpoint tokens (paragraph breaks fall to Nemotron's native
    /// punctuation), and `maxSessionSeconds = .infinity` so the ViewModel never hot-swaps us — a
    /// reset would tear down the Core AI session and discard streaming state.
    let capabilities = EngineCapabilities(
        engineId: "coreai_nemotron",
        displayName: "Nemotron 3.5 Streaming (Core AI)",
        supportsDiarization: false,
        providesReliableTimestamps: false,
        emitsEndpointTokens: false,
        maxSessionSeconds: .infinity,
        requiresPreparation: true  // loads/compiles the Core AI graphs on first session
    )

    // MARK: - Callbacks

    var onTokens: ((_ finals: [TranscriptionToken], _ partial: [TranscriptionToken]) -> Void)?
    var onError: ((TranscriptionServiceError) -> Void)?
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    // On-device: there is no connection to die, so we never request a reconnect (which would
    // rebuild the engine and discard the streaming session).
    let needsReconnect = false

    // MARK: - Private

    /// English-only for v1 (see the design doc) — the model's 40-locale support is out of
    /// scope while the rest of the app hardcodes English throughout.
    private static let language = "en-US"

    private var session: (any CoreAINemotronSession)?
    private var feedContinuation: AsyncStream<Data>.Continuation?
    private var feedTask: Task<Void, Never>?

    /// The full transcript already emitted to the ViewModel as finals. Mutated only inside the
    /// serial feed loop below, so no locking is needed.
    private var confirmedPrefix = ""

    // MARK: - Lifecycle

    /// Loads the cached Core AI plugin and opens a streaming session. Throws if the plugin
    /// isn't loadable (dylib missing, or below macOS 27) or the model isn't downloaded yet (the
    /// user downloads it from Settings → General), so we never block here on the first-load
    /// ~50s GPU-specialization compile during a live session start.
    func connectAndStart() async throws {
        let plugin: any CoreAINemotronTranscriptionPlugin
        do {
            plugin = try CoreAIPluginLoader.makeNemotronPlugin()
        } catch {
            onError?(.connectionFailed(underlying: error))
            throw TranscriptionServiceError.connectionFailed(underlying: error)
        }
        guard plugin.isModelDownloaded() else {
            let error = TranscriptionServiceError.connectionFailed(underlying: nil)
            onError?(error)
            throw error
        }

        let liveSession: any CoreAINemotronSession
        do {
            liveSession = try await Self.makeSession(plugin: plugin)
        } catch {
            onError?(.connectionFailed(underlying: error))
            throw TranscriptionServiceError.connectionFailed(underlying: error)
        }

        confirmedPrefix = ""
        session = liveSession
        onConnectionStateChange?(.connected)
        startFeedLoop(session: liveSession)
    }

    /// Buffers a chunk of 16 kHz mono Float32 PCM for the serial transcription feed.
    func sendAudioChunk(_ data: Data) {
        feedContinuation?.yield(data)
    }

    /// End-of-audio. Intentionally a no-op: `MacTranscriptionViewModel.stop()` commits the
    /// current partial line (our short live tail) into the transcript before teardown.
    func finalize() {}

    func close() {
        feedContinuation?.finish()
        feedContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        session = nil
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

    // MARK: - Session bridging

    private static func makeSession(
        plugin: any CoreAINemotronTranscriptionPlugin
    ) async throws -> any CoreAINemotronSession {
        try await withCheckedThrowingContinuation { continuation in
            plugin.makeSession(language: language) { session, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let session {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: TranscriptionServiceError.connectionFailed(underlying: nil))
                }
            }
        }
    }

    private static func feed(session: any CoreAINemotronSession, samples: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            session.feed(samples: samples) { text, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: text ?? "")
                }
            }
        }
    }

    // MARK: - Feed Loop

    /// Drains buffered audio through the session serially (feed isn't concurrency-safe) and
    /// hands each resulting full transcript straight to `handlePartial` — no separate callback
    /// needed, unlike FluidAudio's `setPartialCallback`, since `feed` itself returns the
    /// transcript-so-far.
    private func startFeedLoop(session: any CoreAINemotronSession) {
        let stream = AsyncStream<Data> { continuation in
            self.feedContinuation = continuation
        }
        feedTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                do {
                    let full = try await Self.feed(session: session, samples: chunk)
                    self.handlePartial(full)
                } catch {
                    print("⚠️ Core AI Nemotron feed error: \(error)")
                }
            }
        }
    }

    // MARK: - Transcript Bridging

    /// Emits already-segmented finals (one per completed sentence, plus the stable head of an
    /// unpunctuated run) and shows the short remainder as a live partial — identical to
    /// `NemotronTranscriberService.handlePartial`, since both feed the same shape of "running
    /// full transcript" into the shared bridge.
    private func handlePartial(_ full: String) {
        let (finals, partials) = FluidAudioStreamBridge.tokens(
            forFull: full, confirmedPrefix: &confirmedPrefix)
        guard !finals.isEmpty || !partials.isEmpty else { return }
        onTokens?(finals, partials)
    }
}
