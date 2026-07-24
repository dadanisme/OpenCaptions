//
//  SidebarProfileFooter.swift
//  OpenCaptions
//
//  The profile block pinned to the bottom of the sidebar: signed-in identity
//  plus a cog that opens the Settings window. Kept deliberately minimal — Sign
//  Out and other account actions live in `MacSettingsView`.
//

import SwiftUI

struct SidebarProfileFooter: View {
    @Environment(MacAuthManager.self) private var auth

    var body: some View {
        HStack(spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 1) {
                Text(auth.isGuest ? "Offline" : (auth.userName ?? "Signed in"))
                    .appScaledFont(.callout).fontWeight(.medium)
                    .lineLimit(1)
                if auth.isGuest {
                    Text("On this Mac")
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let email = auth.userEmail, !email.isEmpty {
                    Text(email)
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            SettingsLink {
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The signed-in user's photo (Google supplies one; Apple/email don't), falling
    /// back to the SF Symbol placeholder while loading or when no photo exists.
    @ViewBuilder
    private var avatar: some View {
        if auth.isGuest {
            Image(systemName: "laptopcomputer")
                .appScaledFont(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        } else if let photoURL = auth.photoURL {
            AsyncImage(url: photoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholderIcon
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "person.crop.circle.fill")
            .appScaledFont(.title2)
            .foregroundStyle(.secondary)
    }
}
