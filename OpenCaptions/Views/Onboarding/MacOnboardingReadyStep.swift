//
//  MacOnboardingReadyStep.swift
//  OpenCaptions
//
//  Step 6: confirmation. Recaps the chosen mode and capture source, then the
//  coordinator's primary action finishes onboarding and drops into the app.
//

import SwiftUI

struct MacOnboardingReadyStep: View {
    @Environment(MacAuthManager.self) private var auth
    let mode: OnboardingMode
    let source: AudioSource

    private var modeValue: String {
        switch mode {
        case .cloud: return auth.userEmail ?? auth.userName ?? "Signed in"
        case .offline: return "On-device · free"
        }
    }

    private var modeSymbol: String { mode == .offline ? "laptopcomputer" : "cloud" }

    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: "checkmark.circle",
                title: "You're all set",
                subtitle: "Open Captions is ready. Start a session and watch your words appear.",
                isComplete: true
            )

            VStack(spacing: 10) {
                recapRow(symbol: modeSymbol, key: mode == .offline ? "Mode" : "Signed in as", value: modeValue)
                recapRow(symbol: source.systemImage, key: "Capturing", value: source.label)
            }
            .frame(maxWidth: 360)
        }
    }

    private func recapRow(symbol: String, key: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .appScaledFont(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(key.uppercased())
                    .appScaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .appScaledFont(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
