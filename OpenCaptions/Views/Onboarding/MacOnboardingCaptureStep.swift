//
//  MacOnboardingCaptureStep.swift
//  OgmoMac
//
//  Step 4: choose what Ogmo listens to — the microphone alone, or the microphone
//  plus other apps' audio (meetings, calls, videos). Writes the coordinator's
//  `source` binding, which is persisted to the shared `ogmo.audioSource` key on
//  finish so the choice flows to the menu bar and recording bar automatically.
//  System-only capture is intentionally left to the menu bar (not an onboarding
//  choice) to keep the decision binary here.
//

import SwiftUI

struct MacOnboardingCaptureStep: View {
    @Binding var source: AudioSource

    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: "mic",
                title: "What should Ogmo listen to?",
                subtitle: "You can change this anytime from the menu bar or the recording bar."
            )

            VStack(spacing: 12) {
                MacOnboardingCard(
                    systemImage: "mic",
                    title: "Microphone",
                    description: "Just your voice. Perfect for notes, dictation, and interviews.",
                    isSelected: source == .microphone
                ) { source = .microphone }

                MacOnboardingCard(
                    systemImage: "waveform.badge.mic",
                    title: "Microphone + System Audio",
                    badge: "meetings",
                    description: "Your voice plus audio from meetings, calls, and videos playing on your Mac.",
                    isSelected: source == .microphoneAndSystem
                ) { source = .microphoneAndSystem }
            }
            .frame(maxWidth: 420)
        }
    }
}
