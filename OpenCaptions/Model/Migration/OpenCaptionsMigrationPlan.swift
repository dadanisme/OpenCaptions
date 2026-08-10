//
//  OpenCaptionsMigrationPlan.swift
//  OpenCaptions
//
//  Brings a store created under OpenCaptionsSchemaV1 (every install before
//  issue #33) up to OpenCaptionsSchemaV2. The only differences are three
//  dropped, previously optional/defaulted properties — no renames, no type
//  changes, no new non-optional properties, no relationship changes — so a
//  single .lightweight stage covers it; SwiftData/Core Data infers the
//  mapping (drop the columns, keep everything else), no willMigrate/
//  didMigrate code required.
//

import SwiftData

enum OpenCaptionsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [OpenCaptionsSchemaV1.self, OpenCaptionsSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: OpenCaptionsSchemaV1.self,
        toVersion: OpenCaptionsSchemaV2.self
    )
}
