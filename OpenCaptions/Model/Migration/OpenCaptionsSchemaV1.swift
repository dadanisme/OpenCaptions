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
//  TranscriptionLine and ActionItem are UNCHANGED by this migration, so they
//  are referenced by their real top-level types in `models` below rather than
//  duplicated here — a model only needs a versioned copy where its shape
//  actually differs from the current one. SwiftData resolves relationships
//  within a single VersionedSchema's model graph by entity name (the
//  unqualified type name, e.g. "TranscriptionSession"), not Swift type
//  identity — that's what lets TranscriptionLine's/ActionItem's real
//  `@Relationship(inverse:)` declarations (which necessarily reference the
//  current top-level `TranscriptionSession`) still resolve correctly against
//  this file's nested `TranscriptionSession` when SwiftData builds the V1
//  model graph.
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
        @Relationship(deleteRule: .cascade) var actionItems: [ActionItem] = []
        @Relationship(deleteRule: .cascade) var lines: [TranscriptionLine] = []

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
}
