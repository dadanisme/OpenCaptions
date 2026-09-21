//
//  OpenCaptionsMigrationPlan.swift
//  OpenCaptions
//
//  Brings a store created under an older schema up to the current one.
//
//  V1→V2 (issue #33) drops three previously optional/defaulted properties —
//  no renames, no type changes, no new non-optional properties, no
//  relationship changes.
//
//  V2→V3 (the Chat tab) adds one new entity, `ChatMessage`, and one new
//  to-many relationship with an empty default, `TranscriptionSession.chatMessages`
//  — nothing existing is renamed, retyped, or made required.
//
//  Both are therefore .lightweight stages: SwiftData/Core Data infers the
//  mapping (drop the columns / add the empty relationship, keep everything
//  else), so no willMigrate/didMigrate code is required.
//

import SwiftData

enum OpenCaptionsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [OpenCaptionsSchemaV1.self, OpenCaptionsSchemaV2.self, OpenCaptionsSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: OpenCaptionsSchemaV1.self,
        toVersion: OpenCaptionsSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: OpenCaptionsSchemaV2.self,
        toVersion: OpenCaptionsSchemaV3.self
    )
}
