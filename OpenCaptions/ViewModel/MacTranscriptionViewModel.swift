//
//  MacTranscriptionViewModel.swift
//  OpenCaptions
//
//  Standalone macOS transcription state machine. Drives the Soniox engine +
//  MacAudioService and feeds tokens through the (diarization-on) accumulator
//  into an in-memory TranscriberModel, then persists on stop.
//
//  A focused state machine that omits Firestore sync, Live
//  Activity, reconnection, periodic connection
//  reset, pause/resume, and the multi-engine factory (Soniox only here).
//

import AVFoundation
import Foundation
import SwiftData

@Observable
final class MacTranscriptionViewModel {

    // MARK: - Observed state

    /// Finalized transcript lines (speaker-grouped bubbles).
    var finalLines = TranscriberModel()
    /// In-progress partial text shown live below the committed lines.
    var partialLine = ""
    /// Whether a session is actively recording.
    var isRunning = false
    /// Whether the session is paused (socket held open via keepalive).
    var isPaused = false
    /// Mic input level (0…1) for a simple level meter.
    var audioLevel: Float = 0.0
    /// User-facing error (connection failure, mic denied, etc.).
    var errorMessage: String?
    /// True while an on-device engine loads its CoreML model in `connectAndStart()`
    /// (`capabilities.requiresPreparation`). Drives the "Preparing model…" overlay.
    /// Always false for cloud Soniox, which connects near-instantly.
    var isPreparingEngine = false
    /// When the current session began; drives the working (pre-summary) title.
    var sessionStartDate = Date()

    /// Placeholder title shown in the window title bar during recording and
    /// persisted on save (until an AI summary replaces it). Matches the format
    /// `TranscriptionSession.init` derives from an empty title.
    var workingTitle: String {
        "Session " + DateFormatter.localizedString(from: sessionStartDate, dateStyle: .short, timeStyle: .short)
    }

    // MARK: - Internal state (not observed by views)

    @ObservationIgnored var transcriptionService: (any RealtimeTranscriptionEngine)?
    @ObservationIgnored var audio: (any AudioCaptureSource)?
    /// Records the captured audio to a local `.m4a` for playback, when the
    /// "Save session audio" Settings toggle is on. Owned here
    /// (not the per-call push task) so it survives `resume()` re-running `sendData`.
    /// Lifecycle lives in `+AudioRecording`.
    @ObservationIgnored var audioRecorder: SessionAudioRecorder?
    /// Filename of the in-progress recording, stamped onto the session at save.
    @ObservationIgnored var audioFileName: String?
    /// The capture source backing the current session (mic vs system audio).
    /// Set by `makeAudioSource`; read by the live-switch guard.
    @ObservationIgnored var currentSource: AudioSource = .microphone
    /// Samples which app is outputting audio over time, so committed lines can be
    /// attributed to a source app. Non-nil only while capturing system audio.
    /// Lifecycle lives in `+AppMonitor`; queried from `saveTranscriptionLine`.
    @ObservationIgnored var appMonitor: SystemAudioActivityMonitor?
    @ObservationIgnored var pushTask: Task<Void, Error>?
    @ObservationIgnored var flushTask: Task<Void, Never>?
    @ObservationIgnored var accumulator = AccumulatorState()
    @ObservationIgnored var speakerMapping: [Int: String] = [:]
    @ObservationIgnored var modelContainer: ModelContainer?
    @ObservationIgnored var lastAudioLevelUpdate: CFAbsoluteTime = 0
    @ObservationIgnored var lastPartialLineUpdate: CFAbsoluteTime = 0
    @ObservationIgnored var sessionStart: CFAbsoluteTime = 0
    /// Bumped on every service swap/stop to invalidate stale callbacks. Also
    /// serves as a "has this session ever started" signal (0 == never started),
    /// so a reopened window rebinds to a running/paused/failed session instead of
    /// starting a fresh one over it.
    @ObservationIgnored var serviceGeneration = 0

    /// Whether `start()` has ever run for this session. Used by the live view to
    /// decide whether to begin capture (fresh session) or just rebind (window
    /// reopened onto an already-started — possibly paused or failed — session).
    var hasStarted: Bool { serviceGeneration > 0 }
    /// Bumped by `pause()`; each push task captures the value at creation and
    /// refuses to close the socket once it no longer matches. This stops a task
    /// cancelled by a pause from tearing down a socket that a quick resume has
    /// already reused for a fresh push task.
    @ObservationIgnored var pushGeneration = 0

    /// Session-relative active time in seconds; used for bubble timestamps
    /// (Soniox's own per-token timestamps are unreliable, so we use our clock).
    var totalActiveTime: TimeInterval {
        sessionStart == 0 ? 0 : CFAbsoluteTimeGetCurrent() - sessionStart
    }

    // MARK: - Lifecycle

    /// Connects the Soniox engine and begins capture + streaming from the chosen
    /// source. The caller must have obtained the source's permission first (mic
    /// access, or Screen Recording for system audio).
    /// - Parameters:
    ///   - userId: the signed-in user's UID, stamped onto the saved session so
    ///     history is scoped per user.
    ///   - source: the capture source (microphone by default).
    @MainActor
    func start(modelContainer: ModelContainer, userId: String?, source: AudioSource = .microphone) async {
        self.modelContainer = modelContainer
        isRunning = true
        isPaused = false
        errorMessage = nil
        finalLines.clear()
        finalLines.ownerUserId = userId
        partialLine = ""
        accumulator.reset()
        speakerMapping.removeAll()
        sessionStart = CFAbsoluteTimeGetCurrent()
        sessionStartDate = Date()
        isPreparingEngine = false
        serviceGeneration += 1

        // Offline Mode (Settings → Recording) picks the engine: on → on-device Nemotron,
        // off → cloud Soniox. Binary by design — there's no free engine selector. Parakeet
        // is downloaded alongside Nemotron but reserved for a future offline re-transcribe.
        let isOffline = UserDefaults.standard.bool(forKey: LiveSessionStore.offlineModeKey)
        let kind: MacTranscriptionEngineKind = isOffline ? .nemotron : .soniox

        // On-device engines need their CoreML model pre-downloaded (from Settings → Recording).
        // Fail fast with a hint instead of blocking here on a multi-hundred-MB fetch. No audio /
        // recording resources are open yet at this point, so there's nothing to tear down.
        if let manager = kind.modelManager {
            manager.refreshStatus()
            if manager.status != .ready {
                isRunning = false
                errorMessage = "Offline transcription needs the on-device model. Open Settings → Recording to download it, then try again."
                return
            }
        }

        let service = MacTranscriptionEngineFactory.make(
            kind, sonioxConfig: Self.makeSonioxConfig(userName: MacAuthManager.shared.userName))
        transcriptionService = service
        // Build the chosen source (mic or system audio). `makeAudioSource` wires
        // the interruption hook to failSession with source-appropriate copy: a
        // mic device/route change or an SCStream stop surfaces as a session
        // failure instead of silently recording nothing.
        audio = makeAudioSource(source)
        // Open the audio recording (a fresh-UUID .m4a) when the "Save session audio"
        // setting is on. No-op / audio-less when it's off.
        startAudioRecordingIfEnabled()
        // Begin sampling source-app activity when capturing system audio (no-op
        // for a mic-only session). `sessionStart` is already set above, so the
        // monitor's clock aligns with line timestamps.
        startAppMonitorIfNeeded()

        wireCallbacks(service)

        // On-device engines load a CoreML model inside connectAndStart() (seconds on first run);
        // show the "Preparing model…" overlay for the duration. Cloud Soniox skips it.
        isPreparingEngine = service.capabilities.requiresPreparation
        do {
            try await service.connectAndStart()
            isPreparingEngine = false
        } catch {
            isPreparingEngine = false
            isRunning = false
            errorMessage = kind.isOnDevice
                ? "Couldn't load the \(kind.displayName) model."
                : "Couldn't connect to the transcription service."
            // Never streamed a frame — discard the just-opened (empty) recording.
            finishAudioRecording(keepFile: false)
            return
        }

        service.startZombieCheck()
        sendData()
    }

    /// Flushes any buffered text, tears down capture + connection, and persists
    /// the session. Returns the saved session's ID (nil if nothing to save).
    @MainActor
    func stop() async -> PersistentIdentifier? {
        let hadContent = !finalLines.textLines.isEmpty || finalLines.flushedLineCount > 0
            || !partialLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isRunning = false
        isPaused = false
        audioLevel = 0.0

        // Invalidate stale callbacks so a late final can't append after the flush.
        serviceGeneration += 1
        transcriptionService?.onTokens = nil

        if !accumulator.isEmpty { flushAccumulator() }

        if !partialLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lastSpeaker = finalLines.speakers.last ?? 0
            let lastEndMs = finalLines.times.last?.end_ms ?? 0
            let sourceApp = appMonitor?.dominantApp(fromMs: lastEndMs, toMs: lastEndMs)
            saveTranscriptionLine(
                text: partialLine, speaker: lastSpeaker,
                forceNewLine: false, start: lastEndMs, end: lastEndMs, sourceApp: sourceApp
            )
            partialLine = ""
        }

        // Seal the shared Firestore doc (no-op if this session was never shared).
        FirestoreSyncService.shared.endSession()

        transcriptionService?.stopZombieCheck()
        // Kill any keepalive timer left running from a pause before this stop.
        transcriptionService?.stopKeepalive()
        audio?.stop()
        // Stop AFTER the flush/partial-save above so they could still query it.
        stopAppMonitor()
        if let task = pushTask {
            task.cancel()
            pushTask = nil
        } else {
            // No push task (e.g. stopped while paused): close the socket here.
            transcriptionService?.finalize()
            transcriptionService?.close()
        }

        // Finalize the recording. Keep the file only when there's content to save
        // (an empty stop discards it); the file is playable once closed.
        finishAudioRecording(keepFile: hadContent)

        guard hadContent, let container = modelContainer else { return nil }
        let savedID = await finalLines.saveSession(
            to: container.mainContext, title: workingTitle, audioFileName: audioFileName)
        // Automatically re-transcribe for higher accuracy when the user opted in
        // (no-op when the setting is off). Runs in the background; the saved
        // transcript updates in place when it finishes.
        RetranscriptionManager.shared.startAutomatic(sessionID: savedID, container: container)
        return savedID
    }

    /// Tears down capture + connection WITHOUT saving (discard a recording).
    @MainActor
    func discard() {
        isRunning = false
        isPaused = false
        audioLevel = 0.0
        serviceGeneration += 1
        transcriptionService?.onTokens = nil
        transcriptionService?.stopZombieCheck()
        transcriptionService?.stopKeepalive()
        audio?.stop()
        stopAppMonitor()
        pushTask?.cancel()
        pushTask = nil
        transcriptionService?.finalize()
        transcriptionService?.close()
        // Seal the shared Firestore doc so a discarded share doesn't stay `live`.
        FirestoreSyncService.shared.endSession()
        // Discard the recording — nothing will reference it.
        finishAudioRecording(keepFile: false)
        finalLines.clear()
        accumulator.reset()
        partialLine = ""
    }

    /// Aborts a live session on an unrecoverable failure (connection lost, mic
    /// error, audio-route change). Stops capture and tears down the socket, but
    /// KEEPS the transcript so the user can still Stop & Save what was captured.
    /// Guarded on `isRunning || isPaused` so a failure that arrives WHILE PAUSED
    /// (e.g. an audio-route change with the engine paused) still aborts instead
    /// of being silently swallowed, and so overlapping failures fire teardown once.
    @MainActor
    func failSession(message: String) {
        guard isRunning || isPaused else { return }
        isRunning = false
        isPaused = false
        audioLevel = 0.0
        errorMessage = message
        serviceGeneration += 1
        transcriptionService?.onTokens = nil
        transcriptionService?.stopZombieCheck()
        // A pause may have armed keepalive; stop it before tearing the socket down.
        transcriptionService?.stopKeepalive()
        audio?.stop()
        stopAppMonitor()
        pushTask?.cancel()
        pushTask = nil
        // Close deterministically here rather than delegating to the push task:
        // failSession may be invoked FROM that task on a mic-start failure, where
        // the task returns before its own teardown would ever run.
        transcriptionService?.finalize()
        transcriptionService?.close()
        // Seal the shared Firestore doc so a failed share doesn't stay `live`.
        // The transcript is kept locally, so Stop & Save can still persist it.
        FirestoreSyncService.shared.endSession()
        // Close the recording but KEEP the file: a subsequent Stop & Save reuses
        // the kept transcript and stamps this filename onto the session.
        finishAudioRecording(keepFile: true)
    }

    /// Renames a speaker for the current session (in-memory only).
    @MainActor
    func rename(speaker id: Int, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        speakerMapping[id] = name
        finalLines.updateName(name: name, id: id)
        // Mirror the rename to the shared session's speakers map (no-op if unshared).
        FirestoreSyncService.shared.updateSpeakerName(speakerId: id, name: name)
    }

    // MARK: - Audio streaming

    /// Pumps 16 kHz mono frames from the mic into ~120 ms chunks and sends them
    /// to the engine. Runs detached so capture never blocks the main thread.
    func sendData() {
        // Capture the current service so teardown always targets THIS session's
        // connection, never a newer one a subsequent start() may have installed.
        let service = transcriptionService
        // Capture the push generation so a task cancelled by a pause won't close
        // the socket a later resume has already reused (see `pushGeneration`).
        let myGeneration = pushGeneration
        pushTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, let audio = self.audio else { return }
            // Owned on the VM so it survives a pause→resume respawning this task.
            let recorder = self.audioRecorder

            let frames: AsyncStream<AudioFrame>
            do {
                frames = try await audio.start()
            } catch {
                // No usable input device / converter, or screen-recording capture
                // couldn't start: don't leave the UI stuck in a fake "Recording"
                // state with a silently-dead pipeline.
                let wasLive = await MainActor.run { () -> Bool in
                    let live = self.isRunning || self.isPaused
                    if live { self.failSession(message: "Couldn't start audio capture.") }
                    return live
                }
                // If a stop() already tore the session down during the source's
                // async startup, failSession no-ops — close the socket here so it
                // can't leak (guarded so a resume that reused it stays untouched).
                if !wasLive, !self.isPaused, self.pushGeneration == myGeneration {
                    service?.finalize()
                    service?.close()
                }
                return
            }

            let chunkDur = 0.12
            let bytesPerSample = MemoryLayout<Float>.size
            let chunkBytesTarget = Int(16_000.0 * chunkDur) * bytesPerSample
            var chunk = Data()
            chunk.reserveCapacity(chunkBytesTarget * 2)

            do {
                for await f in frames {
                    try Task.checkCancellation()
                    if let ch = f.buffer.floatChannelData?.pointee, f.buffer.frameLength > 0 {
                        let frameCount = Int(f.buffer.frameLength)
                        chunk.append(contentsOf: UnsafeRawBufferPointer(
                            start: ch, count: frameCount * bytesPerSample))
                        // Persist the same PCM for playback (segment-aligned above).
                        recorder?.append(f.buffer)

                        var sumOfSquares: Float = 0
                        for i in 0..<frameCount { sumOfSquares += ch[i] * ch[i] }
                        let normalized = min(sqrt(sumOfSquares / Float(frameCount)) * 25.0, 1.0)
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - self.lastAudioLevelUpdate >= 0.1 {
                            self.lastAudioLevelUpdate = now
                            await MainActor.run { self.audioLevel = normalized }
                        }
                        service?.reportAudioLevel(normalized)
                    }
                    if chunk.count >= chunkBytesTarget {
                        service?.sendAudioChunk(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
            } catch is CancellationError {
                // Stopped by stop()/discard()/failSession, OR paused — the
                // isPaused check below decides whether to tear down.
            } catch {
                // Unexpected stream error — fall through to teardown.
            }
            // A pause cancels this task (or ends its stream) but MUST keep the
            // socket open — keepalive holds it until resume() spins up a fresh
            // push task. Only a real stop/discard/failure closes it. The
            // generation guard also stops a task superseded by a resume from
            // closing the socket that resume's fresh task now uses.
            if self.isPaused || self.pushGeneration != myGeneration { return }
            // Flush the final partial chunk, then finalize + close exactly once.
            // Reached whether the loop ended normally OR via cancellation, so the
            // Soniox socket is never left dangling after a Stop & Save.
            if !chunk.isEmpty { service?.sendAudioChunk(chunk) }
            service?.finalize()
            service?.close()
        }
    }

}
