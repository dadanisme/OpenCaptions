//
//  ChatMessage.swift
//  OpenCaptions
//
//  One turn in a session's Chat tab conversation. Persisted as a SwiftData
//  child of `TranscriptionSession` — mirrors `TranscriptionLine`/`ActionItem` —
//  so the conversation survives closing and reopening the session, and app
//  relaunches, instead of resetting every time the session detail view opens.
//  Added to the store by `OpenCaptionsSchemaV3`; see
//  docs/2026-09-16-macos-session-chat.md.
//

import Foundation
import SwiftData

@Model
final class ChatMessage {
    enum Role: String, Equatable {
        case user
        case assistant
    }

    /// Raw storage for `role` — SwiftData persists the primitive; `role`
    /// below is the typed accessor the rest of the app reads/writes.
    var roleRawValue: String
    var text: String
    /// Conversation order — position within the session, oldest first.
    var sortOrder: Int

    var role: Role {
        get { Role(rawValue: roleRawValue) ?? .user }
        set { roleRawValue = newValue.rawValue }
    }

    @Relationship(inverse: \TranscriptionSession.chatMessages)
    var session: TranscriptionSession?

    init(role: Role, text: String, sortOrder: Int) {
        self.roleRawValue = role.rawValue
        self.text = text
        self.sortOrder = sortOrder
    }
}
