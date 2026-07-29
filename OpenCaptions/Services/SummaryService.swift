//
//  SummaryService.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 17/11/25.
//

import Foundation
import SwiftData

// MARK: - Error Types

enum SessionSummaryError: LocalizedError {
    case emptyConversation
    case unauthorized
    case badRequest(String)
    case serverError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .emptyConversation:
            return "There are no valid subtitle records for this conversation, so a summary cannot be generated."
        case .unauthorized:
            return "Unauthorized — check that GEMINI_API_KEY is set correctly in Config.xcconfig."
        case .badRequest(let message):
            return "Bad request: \(message)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }

    var analyticsType: String {
        switch self {
        case .emptyConversation: return "emptyConversation"
        case .unauthorized: return "unauthorized"
        case .badRequest: return "badRequest"
        case .serverError: return "serverError"
        case .networkError: return "networkError"
        }
    }
}

// MARK: - API Response

/// The structured summary contract. Kept identical to the old Cloud Function
/// response so everything downstream (`SummaryViewModel`, `saveStructuredSummary`,
/// the Firestore mirror, the ActionItems/KeyPoints screens) is untouched by the
/// migration to a direct Gemini call. See `SummaryService+Gemini`.
struct SummaryAPIResponse: Decodable {
    let title: String
    let shortDescription: String
    let summary: [String]
    let keyPoints: [String]
    let actionItems: [String]?

    /// Who the model thinks each diarized speaker is — optional in the response
    /// schema, so a transcript with no identity signal simply omits it.
    ///
    /// Wrapped in `SpeakerPredictions` rather than declared `[SpeakerIdentification]?`
    /// on purpose: the synthesized decoder would call `decodeIfPresent` on a plain
    /// array, which THROWS on a type mismatch and would take the whole summary down
    /// with a malformed prediction. `SpeakerPredictions.init(from:)` cannot throw.
    let speakers: SpeakerPredictions?

    /// The speakers the model named — empty when the field was absent, null, or
    /// malformed. The accessor callers should use; see `SpeakerNameResolver`.
    var identifiedSpeakers: [SpeakerIdentification] { speakers?.identifications ?? [] }
}

// MARK: - Summary Service

@MainActor
@Observable
final class SummaryService {

    func summarize(
        session transcriptionSession: TranscriptionSession,
        language: String = "English" // standalone macOS MVP is English-only (LanguageManager deferred)
    ) async throws -> SummaryAPIResponse {
        guard !transcriptionSession.lines.isEmpty else {
            throw SessionSummaryError.emptyConversation
        }

        let transcript = ConversationFormatter.buildTranscript(from: transcriptionSession)
        return try await callSummarizeAPI(transcript: transcript, language: language)
    }

    func saveStructuredSummary(_ response: SummaryAPIResponse, to session: TranscriptionSession, context: ModelContext) {
        session.summaryParagraphs = response.summary
        session.summaryKeyPoints = response.keyPoints

        // Remove existing action items before creating new ones
        for item in session.actionItems {
            context.delete(item)
        }
        session.actionItems = []

        if let items = response.actionItems {
            for (index, itemText) in items.enumerated() {
                let actionItem = ActionItem(text: itemText, sortOrder: index)
                session.actionItems.append(actionItem)
                context.insert(actionItem)
            }
        }
    }
}
