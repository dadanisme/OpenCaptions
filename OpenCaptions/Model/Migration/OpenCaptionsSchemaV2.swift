//
//  OpenCaptionsSchemaV2.swift
//  OpenCaptions
//
//  Frozen snapshot of the on-disk SwiftData schema shipped by issue #33:
//  TranscriptionSession.userId, .cloudSessionId, .hasPassword, and
//  Workspace.userId are gone.
//
//  This file USED to point at the real, current `@Model` types instead of
//  freezing copies — which was fine only for as long as no further schema
//  change landed. Adding `ChatMessage` (`OpenCaptionsSchemaV3`) made that a
//  trap: `TranscriptionSession` gaining a `chatMessages` relationship would
//  have silently changed what "V2" means, leaving a real on-disk V2 store
//  matching NO declared version and failing the migration outright. So V2 is
//  now frozen — never edit it again; a future schema change gets its own new
//  VersionedSchema + migration stage.
//
//  IMPORTANT — a frozen schema must nest EVERY model it references, including
//  ones the migration doesn't change. An earlier version of this file nested
//  only TranscriptionSession and Workspace and left TranscriptionLine/ActionItem
//  pointing at their real top-level types, on the theory (inherited from V1's
//  own comment) that SwiftData resolves relationships by entity name. It does
//  not resolve INVERSES that way: `TranscriptionLine.session` declares
//  `@Relationship(inverse: \TranscriptionSession.lines)` against the LIVE
//  `TranscriptionSession`, which isn't in this graph, so building this schema
//  during migration trapped with "Fatal error: Inverse Relationship does not
//  exist" (`SwiftData/SchemaEntity.swift:609`). Every relationship and its
//  inverse must live inside the same VersionedSchema.
//

import Foundation
import SwiftData

enum OpenCaptionsSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self, Workspace.self]
    }

    /// Mirrors `OpenCaptions/Model/TranscriptionSession.swift` as it shipped
    /// through #58, before the Chat tab added `chatMessages`. Must match the
    /// real on-disk shape exactly.
    @Model
    final class TranscriptionSession {
        var sessionDate: Date
        var sessionTitle: String
        var shortDescription: String?
        var summaryParagraphs: [String] = []
        var summaryKeyPoints: [String] = []
        var durationMs: Int?
        var previewText: String?
        var speakerNamesSummary: String?
        var audioFileName: String?
        var exportFolderName: String?
        @Relationship(inverse: \OpenCaptionsSchemaV2.Workspace.sessions)
        var workspace: OpenCaptionsSchemaV2.Workspace?
        @Relationship(deleteRule: .cascade)
        var actionItems: [OpenCaptionsSchemaV2.ActionItem] = []
        @Relationship(deleteRule: .cascade)
        var lines: [OpenCaptionsSchemaV2.TranscriptionLine] = []

        init(sessionDate: Date = Date(), sessionTitle: String = "", shortDescription: String? = nil) {
            self.sessionDate = sessionDate
            self.sessionTitle = sessionTitle
            self.shortDescription = shortDescription
        }
    }

    /// Mirrors `OpenCaptions/Model/Workspace.swift` as it shipped through #58.
    @Model
    final class Workspace {
        var name: String
        var createdAt: Date
        var exportBookmark: Data?
        @Relationship(deleteRule: .nullify)
        var sessions: [OpenCaptionsSchemaV2.TranscriptionSession] = []

        init(name: String, createdAt: Date = Date()) {
            self.name = name
            self.createdAt = createdAt
        }
    }

    /// Mirrors `OpenCaptions/Model/TranscriptionLine.swift`. Unchanged by both
    /// migrations — nested anyway so this graph owns both ends of the
    /// session↔line relationship (see the file header).
    @Model
    final class TranscriptionLine {
        var text: String
        var speakerId: Int
        var speakerName: String
        var startMs: Int
        var endMs: Int
        var timestamp: Date
        var sourceAppBundleID: String?

        @Relationship(inverse: \OpenCaptionsSchemaV2.TranscriptionSession.lines)
        var session: OpenCaptionsSchemaV2.TranscriptionSession?

        init(
            text: String, speakerId: Int, speakerName: String, startMs: Int, endMs: Int,
            sourceAppBundleID: String? = nil, timestamp: Date = Date()
        ) {
            self.text = text
            self.speakerId = speakerId
            self.speakerName = speakerName
            self.startMs = startMs
            self.endMs = endMs
            self.sourceAppBundleID = sourceAppBundleID
            self.timestamp = timestamp
        }
    }

    /// Mirrors `OpenCaptions/Model/ActionItem.swift`. Nested for the same
    /// reason as `TranscriptionLine` above.
    @Model
    final class ActionItem {
        var text: String
        var isCompleted: Bool
        var sortOrder: Int = 0

        @Relationship(inverse: \OpenCaptionsSchemaV2.TranscriptionSession.actionItems)
        var session: OpenCaptionsSchemaV2.TranscriptionSession?

        init(text: String, isCompleted: Bool = false, sortOrder: Int = 0) {
            self.text = text
            self.isCompleted = isCompleted
            self.sortOrder = sortOrder
        }
    }
}
