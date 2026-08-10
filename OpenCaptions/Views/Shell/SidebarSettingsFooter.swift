//
//  SidebarSettingsFooter.swift
//  OpenCaptions
//
//  A slim row pinned to the bottom of the sidebar that opens the Settings
//  window. There's no account identity to show anymore, so this is pure
//  chrome — styled like the sidebar's own NavSection rows so it reads as one
//  more row in the same family, just outside the List's selection model.
//

import SwiftUI

struct SidebarSettingsFooter: View {
    var body: some View {
        SettingsLink {
            Label("Settings", systemImage: "gearshape")
                .appScaledFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
