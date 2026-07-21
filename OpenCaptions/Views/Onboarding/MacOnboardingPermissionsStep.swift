//
//  MacOnboardingPermissionsStep.swift
//  OpenCaptions
//
//  Step 5: request recording permissions up front. Always requests the microphone
//  (both capture choices need it). When the choice includes system audio, it also
//  surfaces the macOS "Audio Recording" prompt now rather than deferring it to the
//  first recording.
//
//  The mic grant is reliably readable; the system-audio (process-tap) grant has NO
//  status API, so we can only *trigger* its prompt — we can't confirm the result.
//  Continue is never blocked here: recording re-checks and, if denied, shows its
//  own recovery UI. See docs/2026-07-11-macos-onboarding.md.
//

import SwiftUI
import AVFoundation

struct MacOnboardingPermissionsStep: View {
    let source: AudioSource
    @Binding var micGranted: Bool
    @Binding var systemAudioPrimed: Bool

    @State private var micDenied = false
    @State private var isPrimingSystemAudio = false

    private var capturesSystemAudio: Bool { source.capturesSystemAudio }

    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: micGranted ? "checkmark.shield" : "mic",
                title: "Enable recording",
                subtitle: capturesSystemAudio
                    ? "Open Captions needs your microphone, plus permission to record system audio for meetings and videos. Nothing is recorded until you start a session."
                    : "Open Captions needs microphone access to transcribe what you say. Nothing is recorded until you start a session.",
                isComplete: micGranted
            )

            VStack(spacing: 12) {
                microphoneRow
                if capturesSystemAudio { systemAudioRow }
            }
            .frame(maxWidth: 380)
        }
        .onAppear {
            // Pre-fill BOTH states from the current TCC status, so a user who
            // already denied the mic in a prior run lands directly on the "Open
            // System Settings" recovery path instead of a dead-end "Allow" button
            // (macOS won't re-prompt once denied).
            micGranted = MacAudioService.isMicAuthorized
            let status = MacAudioService.micAuthorization
            micDenied = status == .denied || status == .restricted
        }
    }

    // MARK: - Microphone

    private var microphoneRow: some View {
        permissionRow(symbol: "mic", title: "Microphone") {
            if micGranted {
                grantedLabel
            } else if micDenied {
                Button("Open System Settings") { MacAudioService.openMicrophoneSettings() }
                    .controlSize(.small)
            } else {
                Button("Allow") { requestMic() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        } footnote: {
            micDenied
                ? "Microphone access is off. Enable it in System Settings, then return here."
                : "Used to transcribe your voice."
        }
    }

    private func requestMic() {
        Task {
            let granted = await MacAudioService.requestMicPermission()
            micGranted = granted
            micDenied = !granted && MacAudioService.micAuthorization != .notDetermined
        }
    }

    // MARK: - System audio

    private var systemAudioRow: some View {
        permissionRow(symbol: "speaker.wave.2", title: "System Audio") {
            if systemAudioPrimed {
                Label("Requested", systemImage: "checkmark.circle")
                    .appScaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isPrimingSystemAudio {
                ProgressView().controlSize(.small)
            } else {
                Button("Allow") { primeSystemAudio() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        } footnote: {
            systemAudioPrimed
                ? "If macOS asked to record audio, allow it so Open Captions can capture other apps."
                : "Lets Open Captions hear meetings, calls, and videos on this Mac."
        }
    }

    private func primeSystemAudio() {
        isPrimingSystemAudio = true
        Task {
            await SystemAudioTapCaptureService.primeAudioRecordingPermission()
            isPrimingSystemAudio = false
            systemAudioPrimed = true
        }
    }

    // MARK: - Row scaffold

    private var grantedLabel: some View {
        Label("Granted", systemImage: "checkmark.circle.fill")
            .appScaledFont(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.green)
    }

    private func permissionRow<Trailing: View>(
        symbol: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        footnote: () -> String
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .appScaledFont(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appScaledFont(.headline)
                Text(footnote())
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
