//
//  MacTranscriptionViewModel+AudioSource.swift
//  OpenCaptions
//
//  Builds the selected capture source and hot-swaps it live. Kept out of the
//  main view-model file (near the per-file line limit) — the main file just
//  calls `makeAudioSource(_:)` from `start()`.
//
//  A live swap reuses the pause/resume teardown: cancel the streaming task
//  WITHOUT closing the Soniox socket (the `pushGeneration` guard in `sendData`),
//  stop the old source, then spin the pump back up on the new source. The
//  connection, accumulator, and transcript survive the swap.
//

import Foundation

extension MacTranscriptionViewModel {

    /// Builds a capture source for `kind`, records it as the current source, and
    /// wires its interruption hook to fail the session with source-appropriate
    /// copy (keeping the transcript). Callers assign the result to `audio`.
    @MainActor
    func makeAudioSource(_ kind: AudioSource) -> any AudioCaptureSource {
        currentSource = kind
        let source = AudioCaptureSourceFactory.make(kind)
        let message = Self.interruptionMessage(for: kind)
        source.onInterruption = { [weak self] in
            Task { @MainActor in self?.failSession(message: message) }
        }
        // Only the mixed source has an echo canceller. Arm its remote-flag kill
        // switch here (on the main actor, before `start()`): the initial snapshot
        // sets `aecEnabled` for the build gate in `configureMicEngine`, and it then
        // reacts to mid-session flips of `Mac_aec_enabled` (issue #231).
        (source as? MixedAudioCaptureService)?.observeAECFlag()
        return source
    }

    /// Switches the live capture source (e.g. Microphone → System Audio) without
    /// dropping the Soniox connection or the transcript. Returns whether the swap
    /// applied — `false` if the session isn't safely live yet (still connecting /
    /// paused), so the caller can avoid persisting a selection that never took
    /// effect. Callers gate screen-recording permission first.
    @MainActor
    @discardableResult
    func switchAudioSource(to kind: AudioSource) -> Bool {
        guard isRunning, pushTask != nil, kind != currentSource else { return false }

        // Invalidate the current push task's right to close the socket, then
        // cancel it — the isPaused/generation guard in `sendData` keeps Soniox
        // open. We stay live (isRunning/isPaused unchanged), unlike pause().
        pushGeneration += 1
        // Detach the old source's interruption hook first: a deliberate stop
        // must not fire failSession and abort the (still-live) session.
        audio?.onInterruption = nil
        audio?.stop()
        pushTask?.cancel()
        pushTask = nil

        // Swap in the new source and restart the pump on the SAME connection.
        audio = makeAudioSource(kind)
        // Start/stop source-app sampling to match the new source (e.g. begin on
        // Microphone → System Audio, end on the reverse).
        reconcileAppMonitor()
        sendData()
        return true
    }

    /// User-facing failure copy per source, shown when capture dies mid-session.
    private static func interruptionMessage(for kind: AudioSource) -> String {
        switch kind {
        case .microphone:
            return "Audio input changed. Recording stopped — tap End to keep this transcript."
        case .systemAudio:
            return "System audio capture stopped. Recording stopped — tap End to keep this transcript."
        case .microphoneAndSystem:
            return "Audio capture stopped. Recording stopped — tap End to keep this transcript."
        }
    }
}
