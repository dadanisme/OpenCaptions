//
//  MacMinuteDeductionService.swift
//  OpenCaptions
//
//  Persists and sends minute-usage deductions to the backend: a UserDefaults
//  checkpoint plus a `{user_id, minutes}` POST to the `DEDUCT_MINUTES_URL` cloud
//  function, bearer = `SUMMARIZE_API_TOKEN`.
//  Does NOT refresh the RevenueCat balance — the caller must do that after a send.
//

import Foundation

// MARK: - Errors

enum DeductMinutesError: LocalizedError {
    case invalidMinutes
    case unauthorized
    case badRequest(String)
    case serverError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidMinutes:
            return "Minutes to deduct must be a positive number."
        case .unauthorized:
            return "Unauthorized. Please check your API token."
        case .badRequest(let message):
            return "Bad request: \(message)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

private struct DeductErrorResponse: Decodable {
    let error: String
}

// MARK: - Service

final class MacMinuteDeductionService {

    private let pendingDeductionKey = "pending_minutes_to_deduct"

    private var deductMinutesURL: String? {
        guard
            let url = Bundle.main.infoDictionary?["DEDUCT_MINUTES_URL"] as? String,
            !url.isEmpty
        else { return nil }
        return url
    }

    private var apiToken: String? {
        guard
            let token = Bundle.main.infoDictionary?["SUMMARIZE_API_TOKEN"] as? String,
            !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - Pending (UserDefaults)

    var pendingMinutes: Int {
        UserDefaults.standard.integer(forKey: pendingDeductionKey)
    }

    func savePending(_ minutes: Int) {
        guard minutes > 0 else { return }
        UserDefaults.standard.set(minutes, forKey: pendingDeductionKey)
    }

    func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingDeductionKey)
    }

    // MARK: - API

    /// Sends a minute deduction to the backend. On success the caller must refresh the RC balance.
    func send(minutes: Int, userID: String) async throws {
        guard minutes > 0 else { throw DeductMinutesError.invalidMinutes }
        guard let urlString = deductMinutesURL, let url = URL(string: urlString) else {
            throw DeductMinutesError.networkError("DEDUCT_MINUTES_URL not configured in Info.plist.")
        }
        guard let token = apiToken else {
            throw DeductMinutesError.networkError("SUMMARIZE_API_TOKEN not configured in Info.plist.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["user_id": userID, "minutes": minutes]
        )

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw DeductMinutesError.networkError("Invalid response.")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 400:
            let body = try? JSONDecoder().decode(DeductErrorResponse.self, from: data)
            throw DeductMinutesError.badRequest(body?.error ?? "Invalid request")
        case 401:
            throw DeductMinutesError.unauthorized
        default:
            let body = try? JSONDecoder().decode(DeductErrorResponse.self, from: data)
            throw DeductMinutesError.serverError(body?.error ?? "HTTP \(httpResponse.statusCode)")
        }
    }
}
