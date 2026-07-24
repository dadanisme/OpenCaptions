//
//  MacOnboardingModeStep.swift
//  OpenCaptions
//
//  Step 2: the fork. The user chooses a signed-in cloud experience or a free,
//  private, on-device offline experience with no account. Writes the coordinator's
//  `mode` binding; the coordinator decides what the next step becomes.
//

import SwiftUI

struct MacOnboardingModeStep: View {
    @Binding var mode: OnboardingMode?

    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: "arrow.triangle.branch",
                title: "How would you like to use Open Captions?",
                subtitle: "Both give you live transcription. You can switch later in Settings."
            )

            VStack(spacing: 12) {
                MacOnboardingCard(
                    systemImage: "cloud",
                    title: "Sign in",
                    badge: "accurate",
                    description: "Cloud transcription with speaker labels & AI summaries, synced across your Mac and iPhone. Uses your minute balance.",
                    isSelected: mode == .cloud
                ) { mode = .cloud }

                MacOnboardingCard(
                    systemImage: "laptopcomputer",
                    title: "Use offline",
                    badge: "free",
                    badgeTint: .green,
                    description: "Runs entirely on your Mac — private, no account. One download to start. English only — no speaker labels or AI summaries.",
                    isSelected: mode == .offline
                ) { mode = .offline }
            }
            .frame(maxWidth: 420)
        }
    }
}
