//
//  MacOnboardingHeader.swift
//  OgmoMac
//
//  The shared top block of every onboarding step: an SF Symbol in a rounded accent
//  (or success) chip, a title, and a supporting subtitle. Keeps the step subviews
//  consistent and free of layout boilerplate.
//

import SwiftUI

struct MacOnboardingHeader: View {
    /// SF Symbol shown in the accent chip. Ignored when `assetName` is set.
    var systemImage: String?
    /// An asset-catalog image (e.g. the app logo) rendered as a rounded square in
    /// place of the SF Symbol chip. Wins over `systemImage` when present.
    var assetName: String?
    let title: String
    let subtitle: String
    /// Renders the icon chip in green (success) instead of accent — used once the
    /// permission/download it represents is satisfied.
    var isComplete: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            icon

            VStack(spacing: 6) {
                Text(title)
                    .appScaledFont(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .appScaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let assetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let systemImage {
            Image(systemName: systemImage)
                .appScaledFont(.largeTitle)
                .foregroundStyle(isComplete ? Color.green : Color.accentColor)
                .frame(width: 58, height: 58)
                .background(
                    (isComplete ? Color.green : Color.accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .animation(.easeInOut(duration: 0.2), value: isComplete)
        }
    }
}
