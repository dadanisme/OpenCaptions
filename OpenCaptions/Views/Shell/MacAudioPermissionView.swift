//
//  MacAudioPermissionView.swift
//  OgmoMac
//
//  The "access needed" screen shown in place of the live transcript when the mic
//  is denied at session start. Only the microphone has a public preflight, so
//  it's the only permission gated before capture; system-audio capture (Core
//  Audio process tap, #205) prompts for "Audio Recording" on its first start and
//  has no pre-start denied screen. Extracted from MacLiveTranscriptionView to
//  keep that file under the per-file line limit.
//

import AppKit
import SwiftUI

/// Permission status of the desired capture source. `.ok` means "show the
/// transcript"; `.micDenied` renders `MacAudioPermissionView`.
enum AudioAccessState {
    case ok
    case micDenied
}

struct MacAudioPermissionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Microphone Access Needed", systemImage: "mic.slash")
        } description: {
            Text("Enable microphone access in System Settings › Privacy & Security › Microphone, then try again.")
        } actions: {
            Button("Open System Settings") { openSettings() }
        }
    }

    private func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
