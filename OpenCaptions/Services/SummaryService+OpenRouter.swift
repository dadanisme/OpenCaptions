//
//  SummaryService+OpenRouter.swift
//  OpenCaptions
//
//  The summary transport: an OpenAI-compatible chat-completions call to OpenRouter
//  (bring-your-own `OPENROUTER_API_KEY`), so summaries still need no backend server.
//
//  This replaced a direct call to Google Gemini's `generateContent` REST endpoint
//  (2026-08-04). Gemini's public API returns overload errors — 503 UNAVAILABLE /
//  429 RESOURCE_EXHAUSTED — often enough to be a real annoyance, and that transport
//  had no retry: an overloaded upstream failed the whole summary. OpenRouter fronts
//  several upstream providers for the same model, so a saturated one is routed
//  around rather than surfaced. See docs/2026-08-04-macos-openrouter-summaries.md.
//
//  The prompt itself remains a client-side port of the old
//  `ogmo-cf/summarizeTranscript.ts` Cloud Function; `SummaryAPIResponse` (and
//  everything downstream of it) is unchanged by either migration.
//
//  The offline-mode gate lives upstream (the session-detail auto-summarize and
//  `PostSessionRetranscriber` both skip generation when Offline Mode is on), so
//  this file always assumes network is available.
//

import Foundation

extension SummaryService {

    /// Pinned — there is deliberately no user-facing model picker. Google's fast,
    /// low-cost model, and one OpenRouter serves from both Google Vertex and Google
    /// AI Studio, so `allow_fallbacks` below has somewhere to go.
    private static let model = "deepseek/deepseek-v4-flash"
    private static let endpoint = "https://openrouter.ai/api/v1/chat/completions"

    /// Statuses worth another attempt: rate-limited upstream (429), no provider
    /// currently meeting the routing requirements (503), a down/garbled upstream
    /// (502), and a request that timed out on OpenRouter's side (408).
    private static let retryableStatuses: Set<Int> = [408, 429, 502, 503]

    /// Backoff before each retry, and therefore also the retry count. Bounded on
    /// purpose: the worst case adds ~5 s before the user sees an error, rather than
    /// hanging on a provider outage.
    private static let retryBackoff: [Duration] = [.seconds(1), .seconds(4)]

    /// Ceiling on a server-supplied `Retry-After`, so a long suggested wait can't
    /// stall an interactive summary.
    private static let maxRetryAfterSeconds = 10

    /// Builds and sends the chat-completions request, retrying a saturated upstream,
    /// and decodes the structured summary out of `choices[0].message.content`.
    ///
    /// Internal (not `private`) because `summarize(session:language:)` lives in the
    /// core `SummaryService.swift` and Swift `private`/`fileprivate` don't cross files.
    func callSummarizeAPI(transcript: String, language: String) async throws -> SummaryAPIResponse {
        let request = try Self.makeRequest(transcript: transcript, language: language)

        // Retained across attempts so the final error can quote what the upstream
        // actually said, not just "everything was busy".
        var overloadDetail: String?

        for attempt in 0...Self.retryBackoff.count {
            let (data, response) = try await Self.send(request)

            if response.statusCode == 200 {
                return try Self.decodeSummary(from: data)
            }

            guard Self.retryableStatuses.contains(response.statusCode) else {
                throw Self.mapError(status: response.statusCode, data: data)
            }

            overloadDetail = Self.errorMessage(from: data)
            if attempt < Self.retryBackoff.count {
                try await Task.sleep(for: Self.retryDelay(attempt: attempt, response: response))
            }
        }

        // Every attempt came back rate-limited or unavailable.
        throw SessionSummaryError.overloaded(overloadDetail)
    }

    // MARK: - Config

    /// Prefers the runtime value entered in Settings → API Keys (Keychain-backed,
    /// `APIKeyStore`) over the Config.xcconfig-supplied Info.plist value, so a
    /// prebuilt .app can be handed real credentials without a rebuild.
    private static func apiKey() throws -> String {
        if let runtime = APIKeyStore.read(.openRouter) {
            return runtime
        }
        guard
            let key = Bundle.main.infoDictionary?["OPENROUTER_API_KEY"] as? String,
            !key.isEmpty
        else {
            // A missing key is treated as an auth failure, same as a rejected one.
            throw SessionSummaryError.unauthorized
        }
        return key
    }

    // MARK: - Request

    private static func makeRequest(transcript: String, language: String) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw SessionSummaryError.networkError("Invalid OpenRouter endpoint URL.")
        }
        let key = try apiKey()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A header rather than a query param so the key never lands in URL logs.
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Optional OpenRouter attribution: labels the app on the account's activity
        // page. Neither header affects routing or billing.
        request.setValue("https://github.com/dadanisme/OpenCaptions", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Open Captions", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(transcript: transcript, language: language)
        )
        return request
    }

    private static func requestBody(transcript: String, language: String) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system", "content": systemInstruction(language: language)],
                ["role": "user", "content": transcript]
            ],
            // The OpenAI-compatible spelling of what used to be
            // `generationConfig.responseSchema`. `strict` asks providers with a
            // native strict mode to enforce the schema exactly; `required` stays a
            // subset, so `actionItems` and `speakers` remain genuinely optional.
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "session_summary",
                    "strict": true,
                    "schema": responseSchema
                ]
            ],
            // The point of the migration — let OpenRouter route around a saturated
            // upstream. `require_parameters` stops it falling back onto an endpoint
            // that would ignore `response_format` and hand back prose.
            "provider": [
                "allow_fallbacks": true,
                "require_parameters": true
            ]
        ]
    }

    // `responseSchema` lives in `SummaryService+Schema.swift`.

    // MARK: - Transport

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw SessionSummaryError.networkError(error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw SessionSummaryError.networkError("Invalid response from OpenRouter.")
        }
        return (data, httpResponse)
    }

    /// Honors `Retry-After` when OpenRouter sends one (clamped), else the fixed backoff.
    private static func retryDelay(attempt: Int, response: HTTPURLResponse) -> Duration {
        if
            let header = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Int(header.trimmingCharacters(in: .whitespaces)),
            seconds > 0
        {
            return .seconds(min(seconds, maxRetryAfterSeconds))
        }
        return retryBackoff[min(attempt, retryBackoff.count - 1)]
    }

    // MARK: - Error mapping

    private static func mapError(status: Int, data: Data) -> SessionSummaryError {
        let message = errorMessage(from: data)
        switch status {
        case 401:
            // OpenRouter returns a genuine 401 for a missing, disabled, or invalid
            // key — unlike Gemini, which reported it as 400 INVALID_ARGUMENT and
            // needed the message-sniffing hack this replaced.
            return .unauthorized
        case 402:
            return .insufficientCredits
        case 400, 403:
            // 403 is a guardrail / moderation block; `errorMessage` folds the
            // reasons out of `error.metadata` for it.
            return .badRequest(message ?? "Invalid request.")
        default:
            return .serverError(message ?? "HTTP \(status)")
        }
    }
}
