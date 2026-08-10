//
//  OpenCaptionsSchemaV2.swift
//  OpenCaptions
//
//  The trimmed shape shipped by issue #33: TranscriptionSession.userId,
//  .cloudSessionId, .hasPassword, and Workspace.userId are gone. Unlike
//  SchemaV1 this is NOT a frozen copy — it points at the real, current
//  @Model types in OpenCaptions/Model/, so a future schema change adds a new
//  SchemaV3 instead of editing this file.
//

import Foundation
import SwiftData

enum OpenCaptionsSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TranscriptionSession.self, TranscriptionLine.self, ActionItem.self, Workspace.self]
    }
}
