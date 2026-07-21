//
//  ActionItem.swift
//  unmute
//

import Foundation
import SwiftData

/// Single action item from a summary, with persisted completion state
@Model
final class ActionItem {
    var text: String
    var isCompleted: Bool
    var sortOrder: Int = 0

    @Relationship(inverse: \TranscriptionSession.actionItems)
    var session: TranscriptionSession?

    init(text: String, isCompleted: Bool = false, sortOrder: Int = 0) {
        self.text = text
        self.isCompleted = isCompleted
        self.sortOrder = sortOrder
    }
}
