//
//  Workspace.swift
//  OpenCaptions
//
//  A named container sessions can be filed under (e.g. "Work" vs. personal), so
//  they can be filtered in the sidebar and, optionally, exported to their own
//  folder instead of the shared default (see `Workspace+Export.swift` and
//  `SessionExportCoordinator`). A session belongs to at most one workspace —
//  deliberately not many-to-many, so its export root is never ambiguous.
//

import Foundation
import SwiftData

@Model
final class Workspace {
    var name: String
    var createdAt: Date
    /// Firebase UID of the owner, same convention as `TranscriptionSession.userId`.
    /// A workspace is per-account data, not a device-local preference.
    var userId: String?
    /// App-scoped security-scoped bookmark for this workspace's own export root.
    /// Nil means "use the default export location" (`MarkdownExportLocation`).
    var exportBookmark: Data?

    /// `.nullify`, not `.cascade`: deleting a workspace must never delete the
    /// sessions filed under it — they fall back to the default export location
    /// instead (see `SessionExportCoordinator.deleteWorkspace`).
    @Relationship(deleteRule: .nullify)
    var sessions: [TranscriptionSession] = []

    init(name: String, userId: String? = nil, createdAt: Date = Date()) {
        self.name = name
        self.userId = userId
        self.createdAt = createdAt
    }
}
