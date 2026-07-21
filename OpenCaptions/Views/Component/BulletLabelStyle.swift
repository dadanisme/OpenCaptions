//
//  BulletLabelStyle.swift
//  OgmoMac
//
//  Renders a small bullet before the label text. Used by the session-detail
//  summary's "Key Points" list. Extracted from MacSessionDetailView to keep that
//  file under the line limit.
//

import SwiftUI

/// A `LabelStyle` that renders a small leading bullet before the title.
struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .appScaledFont(.caption2)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
