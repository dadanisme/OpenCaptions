//
//  MacTranscriptionViewModel+AudioRecording.swift
//  OpenCaptions
//
//  Session-audio recording lifecycle: opening/closing the `.m4a` recorder and
//  the remote-flag kill switch. Split out of the main view model to keep it
//  under the line limit. See docs and issue #198.
//

import Foundation
import Observation

extension MacTranscriptionViewModel {
    /// Whether audio recording is permitted right now: the remote kill switch AND
    /// the per-device Settings toggle must both be on.
    @MainActor
    var isAudioRecordingEnabled: Bool {
        FeatureFlagService.shared.isEnabled(.sessionPlayback)
            && UserDefaults.standard.bool(forKey: LiveSessionStore.sessionAudioKey)
    }

    /// Opens a recorder for this session when recording is enabled, then arms the
    /// remote-flag kill switch. A fresh UUID names the file (no session row exists
    /// yet). Failure to open is non-fatal — transcription proceeds audio-less.
    @MainActor
    func startAudioRecordingIfEnabled() {
        guard isAudioRecordingEnabled else { return }
        let name = UUID().uuidString + ".m4a"
        guard let recorder = SessionAudioRecorder(fileName: name) else { return }
        audioRecorder = recorder
        audioFileName = name
        observeAudioFlag()
    }

    /// Finalizes the recording. `keepFile` maps to whether the session is being
    /// saved: when false the file is deleted (by name, so it's removed even if the
    /// recorder was already closed by an earlier `failSession`) and `audioFileName`
    /// is cleared so a later save can't stamp a deleted file. When true the closed
    /// file is playable and `audioFileName` is retained for `saveSession` to stamp.
    @MainActor
    func finishAudioRecording(keepFile: Bool) {
        audioRecorder?.close(deletingFile: !keepFile)
        audioRecorder = nil
        if !keepFile {
            SessionAudioStore.delete(fileName: audioFileName)
            audioFileName = nil
        }
    }

    /// Tears down an in-progress recording if the remote flag flips off
    /// mid-session, discarding the partial file so nothing half-recorded is kept.
    /// Mirrors `FirestoreSyncService.observeSessionSharingFlag`'s self-re-arming
    /// `withObservationTracking` (one-shot API, so re-arm on each fire), and only
    /// stays armed while a recording is active.
    @MainActor
    func observeAudioFlag() {
        // `[weak self]` MUST be on the OUTER onChange closure: withObservationTracking
        // registers this handler with FeatureFlagService.shared's (immortal) registrar,
        // so a strong capture would pin this per-session view model alive until the flag
        // next changes. A nested `Task { [weak self] }` would NOT prevent the outer
        // closure from strongly capturing self.
        withObservationTracking {
            _ = FeatureFlagService.shared.isEnabled(.sessionPlayback)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.audioRecorder != nil else { return }
                if !FeatureFlagService.shared.isEnabled(.sessionPlayback) {
                    self.finishAudioRecording(keepFile: false)
                } else {
                    self.observeAudioFlag()  // re-arm; still recording
                }
            }
        }
    }
}
