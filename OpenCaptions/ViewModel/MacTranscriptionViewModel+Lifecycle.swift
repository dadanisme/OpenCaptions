//
//  MacTranscriptionViewModel+Lifecycle.swift
//  OpenCaptions
//
//  Pause / resume for the standalone macOS transcription flow. A soft pause
//  stops mic capture but holds the Soniox socket open via keepalive, so a
//  resume continues the same session. There's no Firestore / Live Activity /
//  analytics, and
//  no reconnection (this target can't reconnect, so a socket that dies during
//  a pause fails the session on resume while keeping the transcript).
//

import Foundation

extension MacTranscriptionViewModel {

    /// Pauses transcription: stops audio but keeps the connection alive. Returns
    /// whether a pause actually happened, so callers (the Pause/Resume global
    /// hotkey) can give accurate feedback instead of assuming success.
    @MainActor
    @discardableResult
    func pause() -> Bool {
        // Require an active push task, not just `isRunning`: `start()` flips
        // `isRunning` true before the connect finishes and `sendData()` spins up
        // the task, so pausing during that window would leave `isPaused` set
        // while `start()` goes on to (re)start capture.
        guard isRunning, pushTask != nil else { return false }
        isRunning = false
        isPaused = true
        audioLevel = 0.0
        // Invalidate the current push task's right to close the socket, so a
        // quick resume that reuses this socket can't be torn down by the task
        // this pause is about to cancel.
        pushGeneration += 1

        // Soft pause — stops mic frames but keeps the tap installed.
        audio?.pause()
        // Suspend source-app sampling too (no audio → no lines to attribute).
        appMonitor?.pause()

        // Cancel the streaming task without closing the socket (the isPaused +
        // generation guard in sendData's teardown keeps it open).
        pushTask?.cancel()
        pushTask = nil

        // Paused = no audio = no tokens, which would trip the zombie check;
        // stop it and hold the socket open with keepalive instead.
        transcriptionService?.stopZombieCheck()
        transcriptionService?.startKeepalive()

        // Reflect the paused state on the shared session (no-op if unshared).
        FirestoreSyncService.shared.pauseSession()
        return true
    }

    /// Resumes transcription after `pause()`.
    @MainActor
    func resume() async {
        guard isPaused else { return }
        isPaused = false
        isRunning = true

        // No reconnection on this target: if the socket died during the pause
        // (keepalive should normally prevent this), fail the session but keep
        // whatever was already transcribed so Stop & Save still works.
        if transcriptionService?.needsReconnect == true {
            failSession(message: "Connection lost while paused. Session stopped — tap End to keep this transcript.")
            return
        }

        transcriptionService?.stopKeepalive()
        // Fresh timestamp so time spent paused doesn't count toward the timeout.
        transcriptionService?.startZombieCheck()

        do {
            try audio?.resume()
        } catch {
            failSession(message: "Couldn't resume the microphone. Session stopped — tap End to keep this transcript.")
            return
        }
        // Resume source-app sampling on the same clock anchor.
        appMonitor?.resume()

        // Reflect the resumed state on the shared session (no-op if unshared).
        FirestoreSyncService.shared.resumeSession()

        sendData()
    }
}
