//
//  SettingsInfoTip.swift
//  OpenCaptions
//
//  A small "i" button that reveals a setting's explanation in a popover on
//  click, used throughout Settings so each row's helper text is available on
//  demand instead of always sitting inline under the control — the wider
//  detail-column layout no longer forces every row to also show its own
//  paragraph of copy.
//

import SwiftUI

struct SettingsInfoTip: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More info")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(text)
                .appScaledFont(.callout)
                .padding()
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A row's title paired with its info tip, spaced consistently — every
    /// Settings row that has one uses this same "title + (i)" composition.
    static func label(_ title: String, tip: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            SettingsInfoTip(text: tip)
        }
    }
}
