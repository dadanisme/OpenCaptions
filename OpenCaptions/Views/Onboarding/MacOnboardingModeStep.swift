//
//  MacOnboardingModeStep.swift
//  OpenCaptions
//
//  Step 2: the fork. The user chooses cloud (Soniox) or on-device (Nemotron)
//  transcription — a pure accuracy-vs-privacy tradeoff, both free and
//  unmetered. Writes the coordinator's `mode` binding; the coordinator decides
//  what the next step becomes.
//

import SwiftUI

struct MacOnboardingModeStep: View {
    @Binding var mode: OnboardingMode?

    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: "arrow.triangle.branch",
                title: "How should Open Captions transcribe?",
                subtitle: "Both are free and unmetered. You can switch anytime in Settings → General → Offline Mode."
            )

            VStack(spacing: 12) {
                MacOnboardingCard(
                    systemImage: "cloud",
                    title: "Cloud (Soniox)",
                    badge: "accurate",
                    description: "Speaker labels, custom vocabulary, and AI summaries — the most accurate option. Streams audio to Soniox for transcription, so it needs an internet connection.",
                    isSelected: mode == .cloud
                ) { mode = .cloud }

                MacOnboardingCard(
                    systemImage: "laptopcomputer",
                    title: "Offline (on-device)",
                    badge: "private",
                    badgeTint: .green,
                    description: "Transcribes entirely on your Mac — audio never leaves this device. One-time model download, then works with no network. English only, no speaker labels or AI summaries.",
                    isSelected: mode == .offline
                ) { mode = .offline }
            }
            .frame(maxWidth: 420)
        }
    }
}
