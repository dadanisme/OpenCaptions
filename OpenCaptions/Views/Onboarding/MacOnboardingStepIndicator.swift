//
//  MacOnboardingStepIndicator.swift
//  OgmoMac
//
//  The row of progress dots at the top of the onboarding card: a stretched accent
//  capsule for the current step, a filled accent dot for completed steps, and a
//  hairline ring for upcoming ones. Purely a progress read-out — not interactive.
//

import SwiftUI

struct MacOnboardingStepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                dot(for: step)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    @ViewBuilder
    private func dot(for step: OnboardingStep) -> some View {
        if step == current {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 20, height: 8)
        } else if step < current {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
    }
}
