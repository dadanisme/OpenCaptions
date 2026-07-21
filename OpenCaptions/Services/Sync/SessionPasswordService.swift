//
//  SessionPasswordService.swift
//  OgmoMac
//
//  Owner-side session password management (issue #116). Wraps the two
//  Firebase callable functions deployed in `ogmo-cf`:
//
//    setSessionPassword({sessionId, password}) → {ok: true}
//    removeSessionPassword({sessionId})        → {ok: true}
//
//  The Cloud Function bcrypt-hashes the password into `sessionSecrets/` and
//  flips `sessionIndex/{sessionId}.hasPassword` — the client never writes
//  that field (read it back via `FirestoreSyncService.fetchHasPassword`).
//  Auth is automatic: `HTTPSCallable.call` attaches the Firebase Auth ID
//  token, so no API key or Secrets entry is needed.
//
//  Ported from the iOS `unmute` target. The Mac has no `LanguageManager`, so
//  error strings are plain English literals rather than `.localized` keys.
//

import Foundation
import FirebaseFunctions

// MARK: - Error

enum SessionPasswordError: LocalizedError {
    case unauthenticated
    case permissionDenied
    case notFound
    case invalidArgument
    case unknown

    /// `FunctionsError` is internal to the SDK, so callable failures must be
    /// bridged through `NSError` + `FunctionsErrorDomain` and mapped by raw
    /// code. Anything outside the domain (network drop, timeout) is `.unknown`.
    init(from nsError: NSError) {
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            self = .unknown
            return
        }
        switch code {
        case .unauthenticated: self = .unauthenticated
        case .permissionDenied: self = .permissionDenied
        case .notFound: self = .notFound
        case .invalidArgument: self = .invalidArgument
        default: self = .unknown
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthenticated: return "You need to be signed in to change a session password."
        case .permissionDenied: return "You don't have permission to change this session's password."
        case .notFound: return "This shared session no longer exists."
        case .invalidArgument: return "The password must be between 4 and 256 characters."
        case .unknown: return "Something went wrong. Please try again."
        }
    }

    var analyticsType: String {
        switch self {
        case .unauthenticated: return "unauthenticated"
        case .permissionDenied: return "permissionDenied"
        case .notFound: return "notFound"
        case .invalidArgument: return "invalidArgument"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Service

@MainActor
final class SessionPasswordService {

    static let shared = SessionPasswordService()
    private init() {}

    // MARK: - Constants

    /// The callables are deployed in asia-southeast1; `Functions.functions()`
    /// without a region defaults to us-central1 and would fail with notFound.
    private static let region = "asia-southeast1"
    private static let timeoutSeconds: TimeInterval = 30

    /// Server-enforced password length bounds, mirrored client-side so the UI
    /// can validate without a round-trip.
    static let passwordLengthRange = 4...256

    private enum Callable {
        static let set = "setSessionPassword"
        static let remove = "removeSessionPassword"
    }

    // MARK: - Public API

    /// Sets or changes the session's password. Caller should pre-validate the
    /// length against `passwordLengthRange` for a friendlier inline error.
    func setPassword(sessionId: String, password: String) async throws {
        try await invoke(Callable.set, data: [
            "sessionId": sessionId,
            "password": password,
        ])
    }

    /// Removes the session's password protection.
    func removePassword(sessionId: String) async throws {
        try await invoke(Callable.remove, data: [
            "sessionId": sessionId,
        ])
    }

    // MARK: - Internals

    private func invoke(_ name: String, data: [String: Any]) async throws {
        let callable = Functions.functions(region: Self.region).httpsCallable(name)
        callable.timeoutInterval = Self.timeoutSeconds
        do {
            let result = try await callable.call(data)
            guard let payload = result.data as? [String: Any],
                  payload["ok"] as? Bool == true else {
                throw SessionPasswordError.unknown
            }
        } catch let error as SessionPasswordError {
            throw error
        } catch {
            throw SessionPasswordError(from: error as NSError)
        }
    }
}
