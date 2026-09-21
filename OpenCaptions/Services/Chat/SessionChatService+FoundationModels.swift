//
//  SessionChatService+FoundationModels.swift
//  OpenCaptions
//
//  The on-device Chat transport: Apple's Foundation Models framework
//  (`LanguageModelSession`), no network call, no API key. Sibling to
//  `SessionChatService+OpenRouter.swift`, and the exact counterpart of
//  `SummaryService+FoundationModels.swift` for the summary side.
//
//  Rebuilds a `FoundationModels.Transcript` from the persisted `[ChatMessage]`
//  history on EVERY call rather than keeping one `LanguageModelSession` alive
//  across turns. Apple's own multi-turn guidance is to reuse a live session (it
//  keeps its own KV cache, avoiding reprocessing the whole conversation each
//  time), but that means holding `@available(macOS 26, *)`-only state on
//  `SessionChatService`, a class that isn't itself gated — so: type-erased
//  storage plus invalidation logic for every way the "same conversation"
//  assumption can break (provider switched mid-conversation, a different session
//  opened, the chat cleared, app relaunch). `ask(session:messages:)` already
//  receives the complete history including the new question on every call, so
//  rebuilding needs no plumbing at all and every one of those invalidation cases
//  just falls out. The trade is no KV-cache reuse on a second+ turn.
//
//  The 4096-token window holds the instructions, the WHOLE session transcript,
//  and every turn so far — so it fills far faster here than for a one-shot
//  summary, and a long session will overflow on the very first question. That's
//  reported as `.onDeviceContextExceeded` (telling the user to switch providers)
//  rather than silently answering from a truncated transcript.
//
//  See docs/2026-09-16-macos-session-chat.md.
//

import Foundation
import FoundationModels

@available(macOS 26, *)
extension SessionChatService {

    func callFoundationModelsAPI(session: TranscriptionSession, messages: [ChatMessage]) async throws -> String {
        guard let question = messages.last else { throw SessionChatError.emptyConversation }
        let transcript = ConversationFormatter.buildTranscript(from: session)
        let languageModelSession = LanguageModelSession(
            transcript: Self.buildTranscript(sessionTranscript: transcript, priorMessages: messages.dropLast())
        )
        do {
            let response = try await languageModelSession.respond(to: question.text)
            return response.content
        } catch {
            guard AppleIntelligenceContextWindow.isExceeded(error) else {
                throw SessionChatError.onDeviceUnavailable(error.localizedDescription)
            }
            throw SessionChatError.onDeviceContextExceeded(
                await AppleIntelligenceContextWindow.overflowDetail(for: error, text: transcript)
            )
        }
    }

    /// Builds a `Transcript` seeded with the system instructions plus every prior
    /// conversation turn. `priorMessages` excludes the newest question, which the
    /// caller passes to `respond(to:)` instead — passing it here too would ask the
    /// model to answer a prompt it has already "seen" answered.
    ///
    /// Two initializer gotchas worth keeping:
    /// - `Transcript.Instructions(segments:toolDefinitions:)` — `toolDefinitions`
    ///   has no default; it must be passed explicitly.
    /// - `Transcript.Response` has two initializers, `init(id:assetIDs:segments:)`
    ///   (macOS 26+) and `init(id:metadata:segments:)` (macOS 27+ only). Calling
    ///   `Transcript.Response(segments:)` alone resolves to the 27-only overload
    ///   and fails to build under this macOS 26 gate — so `assetIDs: []` is passed
    ///   explicitly to select the right one.
    private static func buildTranscript(
        sessionTranscript: String,
        priorMessages: some Sequence<ChatMessage>
    ) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: systemInstruction(transcript: sessionTranscript)))],
                toolDefinitions: []
            )),
        ]
        for message in priorMessages {
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: message.text))]
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: message.text))]
                )))
            }
        }
        return Transcript(entries: entries)
    }
}
