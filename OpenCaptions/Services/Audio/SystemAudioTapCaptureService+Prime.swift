//
//  SystemAudioTapCaptureService+Prime.swift
//  OpenCaptions
//
//  Onboarding helper: surfaces the macOS "Audio Recording" TCC prompt up front,
//  instead of deferring it to the first system-audio recording.
//
//  A Core Audio process tap has NO preflight/request API and NO status API — the
//  OS shows the prompt on the first `AudioDeviceStart` and never reports the
//  result back to us. So the most we can do outside a real session is *trigger*
//  the prompt by briefly starting and tearing down a tap. We can't confirm the
//  outcome; the recording path still starts optimistically (silence until the
//  user allows it). See docs/2026-07-06-macos-mic-system-audio-fix.md.
//

import Foundation

extension SystemAudioTapCaptureService {

    /// Briefly starts and stops a process tap so macOS shows the one-time "Audio
    /// Recording" permission prompt during onboarding. Idempotent and best-effort:
    /// a build/start failure (e.g. no default output device) is swallowed, and once
    /// the grant exists this is a harmless no-op. The short delay lets the TCC
    /// prompt register before teardown — the dialog persists regardless.
    static func primeAudioRecordingPermission() async {
        let probe = SystemAudioTapCaptureService()
        _ = try? await probe.start()
        try? await Task.sleep(for: .milliseconds(400))
        probe.stop()
    }
}
