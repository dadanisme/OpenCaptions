//
//  OpenCaptionsSchemaV3.swift
//  OpenCaptions
//
//  The current shape: adds the `ChatMessage` entity and
//  `TranscriptionSession.chatMessages`, the per-session Chat tab conversation
//  (see docs/2026-09-16-macos-session-chat.md).
//
//  Unlike V1/V2 this is NOT a frozen copy — it points at the real, current
//  `@Model` types in `OpenCaptions/Model/`, so the live declarations stay the
//  single source of truth for the newest version. The next schema change
//  freezes this file the way V2 was frozen and adds a SchemaV4.
//

import Foundation
import SwiftData

enum OpenCaptionsSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self, Workspace.self, ChatMessage.self]
    }
}
