//
//  MacOnboardingCard.swift
//  OgmoMac
//
//  A large selectable option card used by the Mode and Capture onboarding steps:
//  a leading SF Symbol chip, a title with an optional badge, a description, and a
//  trailing checkmark when selected. Selection is shown with an accent border +
//  tint ring, matching the app's native, material-light aesthetic.
//

import SwiftUI

struct MacOnboardingCard: View {
    let systemImage: String
    let title: String
    /// Optional short pill after the title (e.g. "free", "syncs"). `tint` colors it.
    var badge: String?
    var badgeTint: Color = .accentColor
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .appScaledFont(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .appScaledFont(.headline)
                        if let badge {
                            Text(badge)
                                .appScaledFont(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(badgeTint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(badgeTint.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(description)
                        .appScaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark.circle.fill")
                    .appScaledFont(.title3)
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    // Decorative — selection is conveyed to VoiceOver by the button's
                    // .isSelected trait below, not by announcing a checkmark on every card.
                    .accessibilityHidden(true)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
