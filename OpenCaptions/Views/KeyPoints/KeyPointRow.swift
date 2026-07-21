//
//  KeyPointRow.swift
//  OgmoMac
//
//  One row in the consolidated Key Points list. Fully READ-ONLY: key points are
//  plain `[String]` with no completion state, so — unlike `ActionItemRow` — there
//  is no toggle. The source session is opened from the group's header row instead.
//  General-UI text uses `.appScaledFont` per the OgmoMac font-scaling standard.
//

import SwiftUI

struct KeyPointRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Bullet indicator, mirroring how key points render in the session
            // detail summary (`BulletLabelStyle`).
            Image(systemName: "circle.fill")
                .appScaledFont(.caption2)
                .imageScale(.small)
                .foregroundStyle(.secondary)

            Text(text)
                .appScaledFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
