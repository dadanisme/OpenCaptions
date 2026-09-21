//
//  SessionChatService+OpenRouter.swift
//  OpenCaptions
//
//  The cloud Chat transport: an OpenAI-compatible chat-completions call to
//  OpenRouter with the bring-your-own `OPENROUTER_API_KEY`, so Chat needs no
//  backend server — exactly like `SummaryService+OpenRouter.swift`, whose key
//  lookup, attribution headers, endpoint, and error mapping this mirrors.
//
//  Three deliberate differences from the summary transport:
//
//  - **No `response_format`.** A chat answer is free-form prose, not a
//    schema-constrained JSON object, so there's nothing to validate — which also
//    means every model is usable here, not only the structured-output ones
//    `OpenRouterModelKind` is curated for.
//  - **No `provider.require_parameters`.** With no `response_format` to honor,
//    there's no parameter an upstream could silently ignore, so restricting
//    fallbacks would only shrink the pool of providers that can answer.
//  - **No retry loop.** See `SessionChatService`'s own header: a chat answer is
//    interactive, so a busy provider surfaces immediately as a resendable error.
//
//  The model is the same `LiveSessionStore.openRouterModelKind` the Summary
//  Model picker sets. One OpenRouter model choice covers both AI features rather
//  than a second near-identical picker — the same "one provider/model config for
//  both" call `ogmo-cf` made server-side.
//

import Foundation

extension SessionChatService {

    private static let endpoint = "https://openrouter.ai/api/v1/chat/completions"

    func callOpenRouterAPI(session: TranscriptionSession, messages: [ChatMessage]) async throws -> String {
        let transcript = ConversationFormatter.buildTranscript(from: session)
        let request = try Self.makeRequest(transcript: transcript, messages: messages)
        let (data, response) = try await Self.send(request)

        guard response.statusCode == 200 else {
            throw Self.mapError(status: response.statusCode, data: data)
        }
        return try Self.decodeAnswer(from: data)
    }

    // MARK: - Config

    /// Prefers the runtime value entered in Settings → API Keys (Keychain-backed,
    /// `APIKeyStore`) over the Config.xcconfig-supplied Info.plist value — the same
    /// order `SummaryService+OpenRouter.apiKey()` uses, reading the same single key.
    private static func apiKey() throws -> String {
        if let runtime = APIKeyStore.read(.openRouter) {
            return runtime
        }
        guard
            let key = Bundle.main.infoDictionary?["OPENROUTER_API_KEY"] as? String,
            !key.isEmpty
        else {
            // A missing key is treated as an auth failure, same as a rejected one.
            throw SessionChatError.unauthorized
        }
        return key
    }

    // MARK: - Request

    private static func makeRequest(transcript: String, messages: [ChatMessage]) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw SessionChatError.networkError("Invalid OpenRouter endpoint URL.")
        }
        let key = try apiKey()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A header rather than a query param so the key never lands in URL logs.
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/dadanisme/OpenCaptions", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Open Captions", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(transcript: transcript, messages: messages)
        )
        return request
    }

    /// The system instruction, then every turn so far — `messages` already ends
    /// with the new user question, so no separate turn is appended here.
    private static func requestBody(transcript: String, messages: [ChatMessage]) -> [String: Any] {
        let turns = messages.map { message in
            ["role": message.role == .user ? "user" : "assistant", "content": message.text]
        }
        return [
            "model": LiveSessionStore.openRouterModelKind.modelID,
            "messages": [["role": "system", "content": systemInstruction(transcript: transcript)]] + turns,
            "provider": ["allow_fallbacks": true],
        ]
    }

    // MARK: - Transport

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw SessionChatError.networkError(error.localizedDescription)
        }
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw SessionChatError.networkError("Invalid response from OpenRouter.")
        }
        return (data, httpResponse)
    }

    // MARK: - Response

    /// Pulls the assistant's plain-text answer out of a 200 body. A 200 can still
    /// carry a failure — in `error`, in the choice's own `error`, or as a non-`stop`
    /// `finish_reason` — exactly as it can for the summary transport, so all three
    /// are checked rather than reported as an empty answer.
    private static func decodeAnswer(from data: Data) throws -> String {
        guard let envelope = try? envelopeDecoder.decode(ChatCompletionResponse.self, from: data) else {
            throw SessionChatError.serverError("Couldn't read the chat response.")
        }
        if let message = envelope.error?.message {
            throw SessionChatError.serverError(message)
        }

        let choice = envelope.choices?.first
        guard
            let content = choice?.message?.content,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SessionChatError.serverError(finishMessage(choice) ?? "The chat response was empty.")
        }
        return content
    }

    /// `finish_reason` turned into copy that says what went wrong, so an incomplete
    /// generation doesn't read as an empty reply.
    private static func finishMessage(_ choice: ChatCompletionResponse.Choice?) -> String? {
        if let message = choice?.error?.message {
            return "The provider failed mid-generation (\(message))."
        }
        guard let reason = choice?.finishReason, reason != "stop" else { return nil }
        switch reason {
        case "length":
            return "The answer was cut off before it finished — this session or conversation may be too long."
        case "content_filter":
            return "The answer was blocked by the provider's content filter."
        default:
            return "The answer stopped early (\(choice?.nativeFinishReason ?? reason))."
        }
    }

    // MARK: - Error mapping

    private static func mapError(status: Int, data: Data) -> SessionChatError {
        let message = (try? JSONDecoder().decode(ChatErrorResponse.self, from: data))?.error?.message
        switch status {
        case 401:
            return .unauthorized
        case 402:
            return .insufficientCredits
        case 400, 403:
            return .badRequest(message ?? "Invalid request.")
        default:
            return .serverError(message ?? "HTTP \(status)")
        }
    }

    /// The envelope is snake_case (`finish_reason`), so it needs the conversion —
    /// unlike the summary transport, there's no camelCase JSON payload nested
    /// inside `content` here that a plain decoder would have to handle separately.
    private static let envelopeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

// MARK: - OpenRouter DTOs

/// A near-twin of `SummaryService+OpenRouterResponse`'s own DTOs, which are
/// `private` to that file (Swift `private` doesn't cross files) and carry
/// summary-only concerns such as the moderation-`metadata` unwrapping. Declared
/// separately rather than promoting those to internal, so neither file's decoding
/// can be changed out from under the other.
private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]?
    let error: APIError?

    struct Choice: Decodable {
        let message: Message?
        let finishReason: String?
        let nativeFinishReason: String?
        let error: APIError?
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct APIError: Decodable {
    let message: String?
}

private struct ChatErrorResponse: Decodable {
    let error: APIError?
}
