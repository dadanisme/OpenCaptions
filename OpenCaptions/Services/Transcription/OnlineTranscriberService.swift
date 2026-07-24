//
//  OnlineTranscriberService.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 20/10/25.
//

import Foundation

/// Service class that handles real-time speech-to-text transcription via Soniox WebSocket API.
/// Supports speaker diarization and streaming partial/final transcription results.
final class OnlineTranscriberService: RealtimeTranscriptionEngine {

    // MARK: - Engine Capabilities

    /// Soniox traits: token-level diarization, unreliable per-token timestamps (the ViewModel
    /// uses its own clock), explicit `<end>` endpoint tokens, and a periodic reset matching the
    /// tuned 5-hour connection-reset interval.
    let capabilities = EngineCapabilities(
        engineId: "soniox",
        displayName: "Soniox",
        supportsDiarization: true,
        // Soniox's audio-relative token start_ms/end_ms map straight to the saved-recording
        // file offset and drive session-audio playback seek on macOS, so they are
        // "reliable" here. This keeps the accumulator on start_ms for Soniox; only the on-device
        // engines (Parakeet/Nemotron), which emit 0/0, fall back to the VM clock. See
        // MacTranscriptionViewModel+Accumulator and docs/2026-07-10-macos-on-device-engines.md.
        providesReliableTimestamps: true,
        emitsEndpointTokens: true,
        maxSessionSeconds: TranscriptionConstants.connectionResetIntervalSeconds,
        requiresPreparation: false
    )


    // MARK: - Types

    /// Backwards-compatible alias. The token type now lives in the engine-agnostic
    /// `TranscriptionToken` so Soniox, Gladia, and future engines all emit the same shape.
    typealias Token = TranscriptionToken

    // MARK: - Public Properties

    /// Callback invoked when new tokens are received from the transcription service.
    /// - Parameters:
    ///   - finals: Array of finalized tokens
    ///   - partial: Array of partial (in-progress) tokens
    var onTokens: ((_ finals: [Token], _ partial: [Token]) -> Void)?
    var onError: ((TranscriptionServiceError) -> Void)?
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    // MARK: - Configuration

    /// Type-safe configuration for this Soniox connection
    let config: SonioxConfig

    // MARK: - Init

    init(config: SonioxConfig) {
        self.config = config
    }

    // MARK: - Private Properties

    var task: URLSessionWebSocketTask?
    private let url = URL(
        string: "wss://stt-rt.soniox.com/transcribe-websocket"
    )!

    /// Set when WebSocket dies during pause — checked on resume
    var needsReconnect = false
    var lastTokenTime: Date?
    /// Last time speech-level audio was seen, stamped by `reportAudioLevel`.
    /// Gates the timer-based zombie check so a genuinely silent room is never
    /// mistaken for a dead connection.
    var lastLoudAudioTime: Date?
    var zombieCheckTimer: Timer?
    /// Timer that sends keepalive frames while a session is paused so Soniox
    /// doesn't close the idle socket (it times out after ~20 s of no audio).
    private var keepaliveTimer: Timer?

    /// Guards against signaling .disconnected multiple times from the same instance
    var hasSignaledDisconnect = false

    // MARK: - Public Methods

    /// Establishes WebSocket connection and sends initial configuration.
    /// - Throws: Connection or configuration errors
    func connectAndStart() async throws {
        needsReconnect = false
        hasSignaledDisconnect = false

        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)

        // Start listening for messages before resuming the connection
        receiveLoop()

        // Begin WebSocket connection
        task?.resume()

        // Send configuration as the first frame. URLSessionWebSocketTask queues
        // sends FIFO until the socket finishes its handshake, so this config is
        // still delivered before any audio chunk (audio only starts once this
        // returns). Sending it immediately — rather than after a fixed 500 ms
        // sleep — removes the startup delay and the clipped first ~0.5 s of speech.
        if let json = try? JSONSerialization.data(withJSONObject: config.toDictionary()),
            let jsonString = String(data: json, encoding: .utf8)
        {
            task?.send(.string(jsonString)) { err in
                if let err {
                    print("❌ Error sending config: \(err)")
                }
            }
        }
    }

    /// Sends a chunk of raw PCM audio data to the transcription service.
    /// - Parameter data: Raw Float32 PCM audio data (48kHz, mono)
    func sendAudioChunk(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if let error {
                print("❌ Audio chunk send failed: \(error)")
                self?.onError?(.sendFailed(underlying: error))
                self?.signalDisconnect()
            }
        }
    }

    /// Signals the end of audio stream and requests final transcription results.
    func finalize() {
        guard
            let msg = try? JSONSerialization.data(withJSONObject: [
                "type": "finalize"
            ]),
            let msgString = String(data: msg, encoding: .utf8)
        else {
            return
        }
        task?.send(.string(msgString)) { _ in }
    }

    /// Sends a single keepalive frame to hold the WebSocket open during a pause.
    /// If the socket is already dead, records it for `resume()` via `needsReconnect`.
    func keepalive() {
        guard let task, task.state == .running else {
            needsReconnect = true
            stopKeepalive()
            return
        }
        guard
            let msg = try? JSONSerialization.data(withJSONObject: ["type": "keepalive"]),
            let msgString = String(data: msg, encoding: .utf8)
        else { return }
        task.send(.string(msgString)) { [weak self] error in
            if let error {
                print("❌ Keepalive send failed: \(error)")
                self?.stopKeepalive()
                self?.needsReconnect = true
            }
        }
    }

    /// Starts periodic keepalives (one immediately, then every 15 s — below
    /// Soniox's ~20 s idle timeout) so a paused session's socket stays alive.
    func startKeepalive() {
        stopKeepalive()
        keepalive()
        let timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.keepalive()
        }
        keepaliveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopKeepalive() {
        // The timer is scheduled on RunLoop.main, but this can be called from a
        // background URLSession/send-completion queue (via signalDisconnect or a
        // failed keepalive send). Invalidate — and touch keepaliveTimer — only on
        // the main thread, where startKeepalive also manages it.
        if Thread.isMainThread {
            keepaliveTimer?.invalidate()
            keepaliveTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.keepaliveTimer?.invalidate()
                self?.keepaliveTimer = nil
            }
        }
    }

    /// Closes the WebSocket connection and releases resources.
    func close() {
        // Send empty data frame to signal end
        task?.send(.data(Data())) { _ in }

        // Cancel the WebSocket task
        task?.cancel(with: .goingAway, reason: nil)
    }

    deinit {
        // Invalidate directly (not via stopKeepalive's async main-hop, whose
        // [weak self] would no-op mid-dealloc and leak the timer). We're the sole
        // owner here, and dealloc normally runs on main since the main-actor view
        // model holds the service. In normal flows stop/discard/failSession have
        // already invalidated it on main, so this is a belt-and-suspenders cleanup.
        keepaliveTimer?.invalidate()
        stopZombieCheck()
    }
}
