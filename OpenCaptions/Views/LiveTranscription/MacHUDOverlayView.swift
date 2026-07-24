//
//  MacHUDOverlayView.swift
//  OpenCaptions
//
//  The content of the brief HUD badge shown when a global hotkey fires — a
//  system-volume-style card with an icon + one-line message. Rendered
//  inside a floating, non-activating panel by `MacHUDOverlayController`.
//
//  `HotKeyOutcome` is what a hotkey actually DID (or why it was a no-op), so the
//  same "Pause" chord confirms with "Paused" when it acted or "Not recording"
//  when it didn't. Neutral outcomes (no-ops / prompts) render muted so a
//  mis-timed press reads as informational, not as success.
//

import SwiftUI

enum HotKeyOutcome {
    case recordingStarted, recordingStopped, recordingPaused, recordingResumed
    case captionsShown, captionsHidden
    case notRecording, noSession, resumeFailed
    case permissionNeeded, signInRequired

    var symbol: String {
        switch self {
        case .recordingStarted: return "record.circle.fill"
        case .recordingStopped: return "checkmark.circle.fill"
        case .recordingPaused: return "pause.circle.fill"
        case .recordingResumed: return "play.circle.fill"
        case .captionsShown: return "captions.bubble.fill"
        case .captionsHidden: return "captions.bubble"
        case .notRecording: return "mic.slash"
        case .noSession: return "waveform.slash"
        case .resumeFailed: return "exclamationmark.triangle.fill"
        case .permissionNeeded: return "exclamationmark.triangle.fill"
        case .signInRequired: return "person.crop.circle.badge.exclamationmark"
        }
    }

    var message: String {
        switch self {
        case .recordingStarted: return "Recording started"
        case .recordingStopped: return "Recording saved"
        case .recordingPaused: return "Paused"
        case .recordingResumed: return "Resumed"
        case .captionsShown: return "Captions shown"
        case .captionsHidden: return "Captions hidden"
        case .notRecording: return "Not recording"
        case .noSession: return "No active recording"
        case .resumeFailed: return "Couldn't resume"
        case .permissionNeeded: return "Microphone access needed"
        case .signInRequired: return "Sign in to record"
        }
    }

    /// No-ops, failures, and prompts render muted; real state changes render prominent.
    var isNeutral: Bool {
        switch self {
        case .recordingStarted, .recordingStopped, .recordingPaused,
             .recordingResumed, .captionsShown, .captionsHidden:
            return false
        case .notRecording, .noSession, .resumeFailed,
             .permissionNeeded, .signInRequired:
            return true
        }
    }
}

struct MacHUDOverlayView: View {
    let symbol: String
    let message: String
    /// Muted (secondary) styling for no-ops / prompts; prominent for real events.
    let isNeutral: Bool

    /// The hotkey-confirmation badge.
    init(outcome: HotKeyOutcome) {
        self.symbol = outcome.symbol
        self.message = outcome.message
        self.isNeutral = outcome.isNeutral
    }

    /// A free-form badge (icon + one line) — used for the name-mention cue
    /// and any future non-hotkey HUD.
    init(symbol: String, message: String, isNeutral: Bool = false) {
        self.symbol = symbol
        self.message = message
        self.isNeutral = isNeutral
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isNeutral ? Color.secondary : Color.primary)
            Text(message)
                .font(.headline)
                .foregroundStyle(isNeutral ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .frame(width: 184, height: 152)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

#Preview {
    HStack(spacing: 16) {
        MacHUDOverlayView(outcome: .recordingStarted)
        MacHUDOverlayView(outcome: .notRecording)
        MacHUDOverlayView(symbol: "at.circle.fill", message: "You were mentioned")
    }
    .padding(40)
}
