//
//  ActionItemRow.swift
//  OpenCaptions
//
//  One row in the consolidated Action Items list. Tapping anywhere on the row
//  toggles completion — the only mutation this feature allows (the source session
//  is opened from the group's header row instead). Otherwise read-only: no edit /
//  delete / reorder. General-UI text uses `.appScaledFont` per the OpenCaptions
//  font-scaling standard.
//

import SwiftUI

struct ActionItemRow: View {
    let item: ActionItem
    /// Toggles + persists `isCompleted`. The whole row is the toggle affordance.
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Plain indicator (not a button): the enclosing row owns the tap.
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .appScaledFont(.body)
                .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)

            Text(item.text)
                .appScaledFont(.body)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .strikethrough(item.isCompleted, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
