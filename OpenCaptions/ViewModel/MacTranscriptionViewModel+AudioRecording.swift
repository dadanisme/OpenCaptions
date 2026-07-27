//
//  MacTranscriptionViewModel+AudioRecording.swift
//  OpenCaptions
//
//  Session-audio recording lifecycle: opening and closing the `.m4a` recorder.
//  Split out of the main view model to keep it under the line limit. See docs.
//

import Foundation

extension MacTranscriptionViewModel {
    /// Whether audio recording is permitted right now: the per-device
    /// "Save session audio" Settings toggle.
    @MainActor
    var isAudioRecordingEnabled: Bool {
        UserDefaults.standard.bool(forKey: LiveSessionStore.sessionAudioKey)
    }

    /// Opens a recorder for this session when recording is enabled. A fresh UUID
    /// names the file (no session row exists yet). Failure to open is non-fatal —
    /// transcription proceeds audio-less.
    @MainActor
    func startAudioRecordingIfEnabled() {
        guard isAudioRecordingEnabled else { return }
        let name = UUID().uuidString + ".m4a"
        guard let recorder = SessionAudioRecorder(fileName: name) else { return }
        audioRecorder = recorder
        audioFileName = name
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
}
