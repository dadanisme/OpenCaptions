//
//  OpenCaptionsSchemaV1.swift
//  OpenCaptions
//
//  Frozen snapshot of the on-disk SwiftData schema as it existed before issue
//  #33 (Firebase Auth + Firestore removal). This is the FIRST VersionedSchema
//  this app has ever declared — every schema change before this one was a
//  bare, unversioned property edit on a plain `Schema([...])`. This file
//  exists ONLY so `OpenCaptionsMigrationPlan` has a permanent, compilable name
//  for that historical shape — never edit it again after this ships; a future
//  schema change gets its own new VersionedSchema + migration stage instead.
//
//  TranscriptionLine and ActionItem are UNCHANGED by every migration so far,
//  but they are still nested here rather than referenced by their real
//  top-level types. That is a CORRECTION: this file used to reference the real
//  types, on the theory that SwiftData resolves relationships within a schema's
//  model graph by entity name. It does not resolve INVERSES that way — the real
//  `TranscriptionLine.session` declares `@Relationship(inverse: \TranscriptionSession.lines)`
//  against the LIVE `TranscriptionSession`, which is not in this graph, so
//  building this schema traps with "Fatal error: Inverse Relationship does not
//  exist" (`SwiftData/SchemaEntity.swift:609`). V2 hit exactly that when the
//  Chat tab's V2→V3 migration first made a frozen schema get built for real;
//  V1 carried the same latent bug, unnoticed only because no V1 store has
//  needed migrating on a machine that would have surfaced it. A frozen schema
//  must nest EVERY model it references, so both ends of each relationship live
//  in the same VersionedSchema. Field shapes are untouched — this changes which
//  Swift types declare the graph, never what is on disk.
//

import Foundation
import SwiftData

enum OpenCaptionsSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self, Workspace.self]
    }

    /// Mirrors `OpenCaptions/Model/TranscriptionSession.swift` as it shipped
    /// through #31 (Workspaces), before #33 dropped `userId`, `cloudSessionId`,
    /// and `hasPassword`. Must match the real on-disk shape exactly.
    @Model
    final class TranscriptionSession {
        var sessionDate: Date
        var sessionTitle: String
        var shortDescription: String?
        var userId: String?
        var summaryParagraphs: [String] = []
        var summaryKeyPoints: [String] = []
        var cloudSessionId: String?
        var durationMs: Int?
        var previewText: String?
        var speakerNamesSummary: String?
        var audioFileName: String?
        var exportFolderName: String?
        var hasPassword: Bool = false
        @Relationship(inverse: \OpenCaptionsSchemaV1.Workspace.sessions)
        var workspace: OpenCaptionsSchemaV1.Workspace?
        @Relationship(deleteRule: .cascade)
        var actionItems: [OpenCaptionsSchemaV1.ActionItem] = []
        @Relationship(deleteRule: .cascade)
        var lines: [OpenCaptionsSchemaV1.TranscriptionLine] = []

        init(
            sessionDate: Date = Date(), sessionTitle: String = "", shortDescription: String? = nil,
            cloudSessionId: String? = nil, userId: String? = nil
        ) {
            self.sessionDate = sessionDate
            self.sessionTitle = sessionTitle
            self.shortDescription = shortDescription
            self.cloudSessionId = cloudSessionId
            self.userId = userId
        }
    }

    /// Mirrors `OpenCaptions/Model/Workspace.swift` as it shipped through #31,
    /// before #33 dropped `userId`.
    @Model
    final class Workspace {
        var name: String
        var createdAt: Date
        var userId: String?
        var exportBookmark: Data?
        @Relationship(deleteRule: .nullify)
        var sessions: [OpenCaptionsSchemaV1.TranscriptionSession] = []

        init(name: String, userId: String? = nil, createdAt: Date = Date()) {
            self.name = name
            self.userId = userId
            self.createdAt = createdAt
        }
    }

    /// Mirrors `OpenCaptions/Model/TranscriptionLine.swift` — identical to the
    /// live shape, nested only so this graph owns both ends of the
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

        @Relationship(inverse: \OpenCaptionsSchemaV1.TranscriptionSession.lines)
        var session: OpenCaptionsSchemaV1.TranscriptionSession?

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

        @Relationship(inverse: \OpenCaptionsSchemaV1.TranscriptionSession.actionItems)
        var session: OpenCaptionsSchemaV1.TranscriptionSession?

        init(text: String, isCompleted: Bool = false, sortOrder: Int = 0) {
            self.text = text
            self.isCompleted = isCompleted
            self.sortOrder = sortOrder
        }
    }
}
