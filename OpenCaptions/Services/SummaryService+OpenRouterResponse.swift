//
//  SummaryService+OpenRouterResponse.swift
//  OpenCaptions
//
//  Decoding for OpenRouter's chat-completions reply. The structured summary arrives
//  as a JSON string in `choices[0].message.content` — the Gemini transport this
//  replaced read it from `candidates[0].content.parts[0].text`.
//
//  Split from `SummaryService+OpenRouter` (which owns the transport) to keep both
//  files under the line limit. The two entry points are `static` and internal
//  because Swift `private`/`fileprivate` don't cross files.
//

import Foundation

extension SummaryService {

    /// Pulls `SummaryAPIResponse` out of a 200 response body.
    static func decodeSummary(from data: Data) throws -> SummaryAPIResponse {
        let envelope: OpenRouterResponse
        do {
            envelope = try Self.envelopeDecoder.decode(OpenRouterResponse.self, from: data)
        } catch {
            throw SessionSummaryError.serverError("Couldn't read the summary response.")
        }

        // A 200 can still carry a failure: OpenRouter reports an upstream error that
        // happened mid-generation in the body rather than in the status code.
        if let message = envelope.error?.message {
            throw SessionSummaryError.serverError(message)
        }

        let choice = envelope.choices?.first
        guard
            let content = choice?.message?.content,
            let jsonData = jsonPayload(from: content)
        else {
            throw SessionSummaryError.serverError(
                finishMessage(choice) ?? "The summary response was empty."
            )
        }

        // `content` is itself a JSON string shaped by `response_format` — decode it
        // into the existing contract. A PLAIN decoder on purpose: `SummaryAPIResponse`
        // keys are camelCase, so the envelope's snake_case conversion must not apply.
        do {
            return try JSONDecoder().decode(SummaryAPIResponse.self, from: jsonData)
        } catch {
            // A non-`stop` finish (length cap, content filter, upstream error) can
            // leave truncated JSON that fails to decode — surface why it stopped
            // rather than a generic "malformed".
            throw SessionSummaryError.serverError(
                finishMessage(choice) ?? "The summary response was malformed."
            )
        }
    }

    /// The human-readable message from an error body, for the transport's status
    /// mapping. `nil` when the body isn't an OpenRouter error envelope at all.
    static func errorMessage(from data: Data) -> String? {
        guard
            let apiError = (try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data))?.error
        else {
            return nil
        }
        // A moderation block's own message is just "flagged", which tells the user
        // nothing; the actual reasons sit in `error.metadata`.
        if let reasons = apiError.metadata?.reasons, !reasons.isEmpty {
            return "Blocked by the provider's content filter: \(reasons.joined(separator: ", "))."
        }
        return apiError.message
    }

    // MARK: - Helpers

    /// `finish_reason` / `native_finish_reason` turned into copy that says what went
    /// wrong, so an incomplete generation doesn't read as a decoding bug.
    private static func finishMessage(_ choice: OpenRouterResponse.Choice?) -> String? {
        if let message = choice?.error?.message {
            return "The provider failed mid-generation (\(message))."
        }
        guard let reason = choice?.finishReason, reason != "stop" else { return nil }

        switch reason {
        case "length":
            return "The summary was cut off before it finished — the transcript may be too long."
        case "content_filter":
            return "The summary was blocked by the provider's content filter."
        default:
            return "The summary generation stopped early (\(choice?.nativeFinishReason ?? reason))."
        }
    }

    /// `response_format: json_schema` should make `content` bare JSON, but a
    /// reasoning model occasionally wraps it in a ``` fence anyway. Unwrapping that
    /// is cheaper than failing an otherwise good summary.
    private static func jsonPayload(from content: String) -> Data? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .drop(while: { $0 != "\n" }) // the ``` or ```json opener
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text.data(using: .utf8)
    }

    /// Shared because the envelope is snake_case (`finish_reason`) while the summary
    /// payload inside it is not — see `decodeSummary`.
    private static let envelopeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

// MARK: - OpenRouter DTOs

/// Only the fields the app reads. `code` is deliberately absent: the HTTP status is
/// the authority, and a provider returning a non-numeric code would fail the decode
/// and cost us the message too.
private struct OpenRouterAPIError: Decodable {
    let message: String?
    let metadata: Metadata?

    struct Metadata: Decodable {
        let reasons: [String]?
    }
}

private struct OpenRouterResponse: Decodable {
    let choices: [Choice]?
    let error: OpenRouterAPIError?

    struct Choice: Decodable {
        let message: Message?
        let finishReason: String?
        let nativeFinishReason: String?
        let error: OpenRouterAPIError?
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct OpenRouterErrorResponse: Decodable {
    let error: OpenRouterAPIError?
}
