//
//  SidebarSettingsFooter.swift
//  OpenCaptions
//
//  A slim row pinned to the bottom of the sidebar: the app name + version on
//  the leading side (pure chrome — there's no account identity to show
//  anymore), and a trailing icon-only button that selects the `.settings`
//  `NavSection` (kept outside `List` so it stays pinned below the scrolling
//  content sections).
//

import SwiftUI

struct SidebarSettingsFooter: View {
    @Binding var section: NavSection?

    /// "Open Captions, v1.0" — the marketing version only, not the build
    /// number (`MacSupportSettingsView`'s diagnostics row wants both; this is
    /// just a footer label).
    private var appNameAndVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Open Captions, v\(version)"
    }

    var body: some View {
        HStack {
            Text(appNameAndVersion)
                .appScaledFont(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                section = .settings
            } label: {
                Image(systemName: section == .settings ? "gearshape.fill" : "gearshape")
                    .foregroundStyle(section == .settings ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
