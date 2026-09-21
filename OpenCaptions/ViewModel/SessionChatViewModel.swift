//
//  SessionChatViewModel.swift
//  OpenCaptions
//
//  Drives the session-detail Chat tab: holds the conversation and sends each new
//  question through `SessionChatService`. History is persisted per session via
//  `TranscriptionSession.chatMessages` — `load(session:)` restores it when the
//  session detail view appears, and `send`/`clear` keep the SwiftData store and
//  the in-memory `messages` array in sync, mirroring how `SummaryService`
//  persists action items. See docs/2026-09-16-macos-session-chat.md.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class SessionChatViewModel {
    var messages: [ChatMessage] = []
    var draftQuestion: String = ""
    var isLoading = false
    var errorMessage: String?

    private let service = SessionChatService()

    /// Whether there's a question worth sending right now.
    var canSend: Bool {
        !isLoading && !draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Restores this session's persisted conversation, oldest first. Call once when
    /// the session detail view appears (or the session changes).
    func load(session: TranscriptionSession) {
        messages = session.chatMessages.sorted { $0.sortOrder < $1.sortOrder }
    }

    func send(session: TranscriptionSession, context: ModelContext) async {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }

        // The question is persisted BEFORE the request goes out, so a failed answer
        // still leaves the user's own message in the thread to retry from rather
        // than discarding what they typed.
        draftQuestion = ""
        errorMessage = nil
        persist(ChatMessage(role: .user, text: question, sortOrder: messages.count), to: session, context: context)

        isLoading = true
        defer { isLoading = false }

        do {
            let answer = try await service.ask(session: session, messages: messages)
            persist(ChatMessage(role: .assistant, text: answer, sortOrder: messages.count), to: session, context: context)
        } catch {
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                errorMessage = description
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Deletes this session's persisted conversation ("Clear Chat").
    func clear(session: TranscriptionSession, context: ModelContext) {
        for message in session.chatMessages {
            context.delete(message)
        }
        session.chatMessages = []
        messages = []
        errorMessage = nil
        try? context.save()
    }

    private func persist(_ message: ChatMessage, to session: TranscriptionSession, context: ModelContext) {
        session.chatMessages.append(message)
        context.insert(message)
        messages.append(message)
        try? context.save()
    }
}
