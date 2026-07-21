//
//  SummaryService.swift
//  unmute
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
            return "Unauthorized. Please check your API token in Secrets."
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

struct SummaryAPIResponse: Decodable {
    let title: String
    let shortDescription: String
    let summary: [String]
    let keyPoints: [String]
    let actionItems: [String]?
}

struct SummaryAPIError: Decodable {
    let error: String
}

// MARK: - Summary Service

@MainActor
@Observable
final class SummaryService {
    
    private var summarizeFunctionURL: String = "https://asia-southeast1-ogmo-491906.cloudfunctions.net/summarizeTranscript"
    
    private var summarizeAPIToken: String {
        guard
            let apiKey = Bundle.main.infoDictionary?["SUMMARIZE_API_TOKEN"]
                as? String
        else {
            fatalError(
                "SUMMARIZE_API_TOKEN not found in Info.plist. Make sure it is set in the .xcconfig file."
            )
        }
        return apiKey
    }

    func summarize(session transcriptionSession: TranscriptionSession) async throws -> SummaryAPIResponse {
        guard !transcriptionSession.lines.isEmpty else {
            throw SessionSummaryError.emptyConversation
        }

        let transcript = ConversationFormatter.buildTranscript(from: transcriptionSession)
        return try await callSummarizeAPI(transcript: transcript)
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

    // MARK: - Private

    private func callSummarizeAPI(transcript: String) async throws -> SummaryAPIResponse {
        guard let url = URL(string: summarizeFunctionURL) else {
            throw SessionSummaryError.networkError("Invalid function URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(summarizeAPIToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let language = "English" // standalone macOS MVP is English-only (LanguageManager deferred)
        let body: [String: Any] = ["transcript": transcript, "language": language]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, urlResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw SessionSummaryError.networkError("Invalid response.")
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(SummaryAPIResponse.self, from: data)
        case 400:
            let errorBody = try? JSONDecoder().decode(SummaryAPIError.self, from: data)
            throw SessionSummaryError.badRequest(errorBody?.error ?? "Unknown error")
        case 401:
            throw SessionSummaryError.unauthorized
        case 405:
            throw SessionSummaryError.badRequest("Method not allowed")
        default:
            let errorBody = try? JSONDecoder().decode(SummaryAPIError.self, from: data)
            throw SessionSummaryError.serverError(errorBody?.error ?? "HTTP \(httpResponse.statusCode)")
        }
    }

}
