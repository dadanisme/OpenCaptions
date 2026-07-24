//
//  SummaryService+Gemini.swift
//  OpenCaptions
//
//  The summary transport: a direct call to Google Gemini's `generateContent`
//  REST endpoint (bring-your-own `GEMINI_API_KEY`), so summaries need no backend
//  server. This is a client-side port of the old `ogmo-cf/summarizeTranscript.ts`
//  Cloud Function — only the transport moved; `SummaryAPIResponse` (and everything
//  downstream of it) is unchanged.
//
//  The offline-mode gate lives upstream (the session-detail auto-summarize and
//  `PostSessionRetranscriber` both skip generation when Offline Mode is on), so
//  this file always assumes network is available.
//

import Foundation

extension SummaryService {

    // Gemini's fast, low-cost model — same one the old Cloud Function used.
    private static let model = "gemini-2.5-flash-lite"
    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"

    /// Builds and sends the Gemini `generateContent` request and decodes the
    /// structured summary out of `candidates[0].content.parts[0].text`.
    ///
    /// Internal (not `private`) because `summarize(session:language:)` lives in the
    /// core `SummaryService.swift` and Swift `private`/`fileprivate` don't cross files.
    func callSummarizeAPI(transcript: String, language: String) async throws -> SummaryAPIResponse {
        let apiKey = try geminiAPIKey()

        guard let url = URL(string: Self.endpoint) else {
            throw SessionSummaryError.networkError("Invalid Gemini endpoint URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Passed as a header rather than a `?key=` query param so the key never
        // lands in URL logs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(transcript: transcript, language: language)
        )

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw SessionSummaryError.networkError(error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw SessionSummaryError.networkError("Invalid response from Gemini.")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.decodeSummary(from: data)
        case 400:
            let apiError = Self.decodeError(from: data)
            // A malformed / placeholder key comes back as 400 INVALID_ARGUMENT
            // ("API key not valid…"), not 401/403 — route it to the tailored
            // .unauthorized hint so the fix (set GEMINI_API_KEY) is obvious.
            if Self.isAPIKeyError(apiError) {
                throw SessionSummaryError.unauthorized
            }
            throw SessionSummaryError.badRequest(apiError?.message ?? "Invalid request.")
        case 401, 403:
            throw SessionSummaryError.unauthorized
        default:
            throw SessionSummaryError.serverError(
                Self.decodeError(from: data)?.message ?? "HTTP \(httpResponse.statusCode)"
            )
        }
    }

    // MARK: - Config

    private func geminiAPIKey() throws -> String {
        guard
            let key = Bundle.main.infoDictionary?["GEMINI_API_KEY"] as? String,
            !key.isEmpty
        else {
            // Missing key is treated as an auth failure per the issue's error mapping.
            throw SessionSummaryError.unauthorized
        }
        return key
    }

    // MARK: - Request

    private static func requestBody(transcript: String, language: String) -> [String: Any] {
        [
            "systemInstruction": [
                "parts": [["text": systemInstruction(language: language)]]
            ],
            "contents": [
                ["parts": [["text": transcript]]]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema
            ]
        ]
    }

    /// Mirrors the `responseSchema` from `summarizeTranscript.ts`. `actionItems` is
    /// intentionally omitted from `required` so it stays optional (matching
    /// `SummaryAPIResponse.actionItems: [String]?`). `propertyOrdering` keeps the
    /// generated field order stable.
    private static let responseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "title": ["type": "STRING"],
            "shortDescription": ["type": "STRING"],
            "summary": ["type": "ARRAY", "items": ["type": "STRING"]],
            "keyPoints": ["type": "ARRAY", "items": ["type": "STRING"]],
            "actionItems": ["type": "ARRAY", "items": ["type": "STRING"]]
        ],
        "required": ["title", "shortDescription", "summary", "keyPoints"],
        "propertyOrdering": ["title", "shortDescription", "summary", "keyPoints", "actionItems"]
    ]

    // MARK: - Response

    private static func decodeSummary(from data: Data) throws -> SummaryAPIResponse {
        let decoder = JSONDecoder()

        let envelope: GeminiResponse
        do {
            envelope = try decoder.decode(GeminiResponse.self, from: data)
        } catch {
            throw SessionSummaryError.serverError("Couldn't read the summary response.")
        }

        // A safety-blocked or otherwise empty generation yields no candidate text.
        guard
            let text = envelope.candidates?.first?.content?.parts?.first?.text,
            let jsonData = text.data(using: .utf8)
        else {
            throw SessionSummaryError.serverError(
                blockedReasonMessage(envelope) ?? "The summary response was empty."
            )
        }

        // The candidate text is itself a JSON string (responseMimeType = application/json)
        // shaped by responseSchema — decode it into the existing contract.
        do {
            return try decoder.decode(SummaryAPIResponse.self, from: jsonData)
        } catch {
            // A non-STOP finish (e.g. MAX_TOKENS) can leave truncated JSON that
            // fails to decode — surface why it stopped rather than a generic
            // "malformed".
            throw SessionSummaryError.serverError(
                blockedReasonMessage(envelope) ?? "The summary response was malformed."
            )
        }
    }

    private static func decodeError(from data: Data) -> GeminiErrorResponse.APIError? {
        (try? JSONDecoder().decode(GeminiErrorResponse.self, from: data))?.error
    }

    /// Gemini reports an invalid / placeholder key as HTTP 400 INVALID_ARGUMENT
    /// with an "API key not valid" message — not 401/403 — so detect it here to
    /// map onto `.unauthorized` (the single most common BYO-key misconfiguration).
    private static func isAPIKeyError(_ error: GeminiErrorResponse.APIError?) -> Bool {
        guard let message = error?.message?.lowercased() else { return false }
        return message.contains("api key") || message.contains("api_key")
    }

    private static func blockedReasonMessage(_ response: GeminiResponse) -> String? {
        if let reason = response.promptFeedback?.blockReason {
            return "The transcript was blocked by content safety filters (\(reason))."
        }
        if let finish = response.candidates?.first?.finishReason, finish != "STOP" {
            return "The summary generation stopped early (\(finish))."
        }
        return nil
    }
}

// MARK: - Gemini DTOs

private struct GeminiResponse: Decodable {
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }
    struct Content: Decodable {
        let parts: [Part]?
    }
    struct Part: Decodable {
        let text: String?
    }
    struct PromptFeedback: Decodable {
        let blockReason: String?
    }
}

private struct GeminiErrorResponse: Decodable {
    struct APIError: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }
    let error: APIError
}
