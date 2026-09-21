//
//  LiveSessionStore+ChatProvider.swift
//  OpenCaptions
//
//  The two-way Chat provider selection (OpenRouter / Apple Foundation Models) —
//  the global Settings preference read by `SessionChatService.ask` and by the
//  Chat tab's availability gate. Mirrors `LiveSessionStore+SummaryProvider.swift`
//  exactly; independent of the summary provider selection. See
//  docs/2026-09-16-macos-session-chat.md.
//

import Foundation

extension LiveSessionStore {

    /// UserDefaults key (String) for the two-way Chat provider selection —
    /// `ChatProviderKind.rawValue`. Read by `SessionChatService.ask` to pick the
    /// transport, and by the Chat tab's own availability gate. Bound to the picker
    /// in Settings → AI Models. Default `"openRouter"` (registered in
    /// `OpenCaptionsApp`). `nonisolated` so it can be read from non-MainActor
    /// contexts, matching `summaryProviderKindKey`'s own reasoning.
    nonisolated static let chatProviderKindKey = "opencaptions.chatProvider.kind"

    /// The current two-way Chat provider selection, decoded from
    /// `chatProviderKindKey`. Falls back to `.openRouter` for an unset/invalid raw
    /// value, matching the registered default.
    nonisolated static var chatProviderKind: ChatProviderKind {
        ChatProviderKind(
            rawValue: UserDefaults.standard.string(forKey: chatProviderKindKey) ?? ""
        ) ?? .openRouter
    }
}
