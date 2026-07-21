//
//  TranscriptionError.swift
//  unmute
//

import Foundation

// MARK: - Audio Service Errors

enum AudioServiceError: Error, CustomStringConvertible {
    case sessionSetupFailed(underlying: Error)
    case engineStartFailed(underlying: Error)
    case engineResumeFailed(underlying: Error)
    case microphoneUnavailable

    var description: String {
        switch self {
        case .sessionSetupFailed(let error):
            return "Audio session setup failed: \(error.localizedDescription)"
        case .engineStartFailed(let error):
            return "Audio engine start failed: \(error.localizedDescription)"
        case .engineResumeFailed(let error):
            return "Audio engine resume failed: \(error.localizedDescription)"
        case .microphoneUnavailable:
            return "Microphone is unavailable"
        }
    }

    /// Stable, locale-independent identifier used for analytics grouping.
    var analyticsCode: String {
        switch self {
        case .sessionSetupFailed: return "audio_session_setup_failed"
        case .engineStartFailed: return "audio_engine_start_failed"
        case .engineResumeFailed: return "audio_engine_resume_failed"
        case .microphoneUnavailable: return "microphone_unavailable"
        }
    }
}

// MARK: - Transcription Service Errors

enum TranscriptionServiceError: Error, CustomStringConvertible {
    case connectionFailed(underlying: Error?)
    case sendFailed(underlying: Error)
    case receiveLoopEnded(underlying: Error?)
    case zombieConnection
    case configSendFailed

    var description: String {
        switch self {
        case .connectionFailed(let error):
            return "WebSocket connection failed: \(error?.localizedDescription ?? "unknown")"
        case .sendFailed(let error):
            return "WebSocket send failed: \(error.localizedDescription)"
        case .receiveLoopEnded(let error):
            return "Receive loop ended: \(error?.localizedDescription ?? "unknown")"
        case .zombieConnection:
            return "Zombie connection detected: audio sent but no tokens received"
        case .configSendFailed:
            return "Failed to send configuration to Soniox"
        }
    }

    /// Stable, locale-independent identifier used for analytics grouping.
    var analyticsCode: String {
        switch self {
        case .connectionFailed: return "ws_connection_failed"
        case .sendFailed: return "ws_send_failed"
        case .receiveLoopEnded: return "ws_receive_loop_ended"
        case .zombieConnection: return "ws_zombie_connection"
        case .configSendFailed: return "ws_config_send_failed"
        }
    }
}

// MARK: - Analytics Code Mapping

/// Maps any thrown transcription-pipeline error into a stable, locale-independent
/// identifier suitable for analytics. Falls back to the type name to avoid
/// `error.localizedDescription` strings that vary by system language.
func transcriptionAnalyticsCode(for error: Error) -> String {
    if let svc = error as? TranscriptionServiceError { return svc.analyticsCode }
    if let audio = error as? AudioServiceError { return audio.analyticsCode }
    let nsError = error as NSError
    return "\(nsError.domain).\(nsError.code)"
}

// MARK: - Connection State

enum ConnectionState: Equatable {
    case connected
    case reconnecting(attempt: Int)
    case failed
    case disconnected
}
