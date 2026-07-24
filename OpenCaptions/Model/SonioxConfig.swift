//
//  SonioxConfig.swift
//  OpenCaptions
//

import Foundation

/// Type-safe configuration for the Soniox real-time WebSocket API.
struct SonioxConfig {

    // MARK: - Model

    let model: String = "stt-rt-v5"

    // MARK: - Language

    let languageHints: [String]
    let isLanguageHintsStrict: Bool

    // MARK: - Context

    let context: Context

    // MARK: - Features

    /// Whether to request per-speaker diarization. Configurable so a transcription-only
    /// tier can run with diarization disabled.
    let isSpeakerDiarizationEnabled: Bool
    let isEndpointDetectionEnabled: Bool = true

    // MARK: - Audio Format

    let audioFormat: String = "pcm_f32le"
    let sampleRate: Int = 16000
    let numChannels: Int = 1

    // MARK: - Nested Types

    struct Context {
        let general: [GeneralEntry]
        let terms: [String]
        let text: String?

        struct GeneralEntry {
            let key: String
            let value: String
        }
    }

    // MARK: - Serialization

    /// Converts to the JSON dictionary expected by the Soniox WebSocket API.
    /// Injects `api_key` from `SonioxSecrets` at serialization time.
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "api_key": SonioxSecrets.sonioxAPIKey,
            "model": model,
            "audio_format": audioFormat,
            "sample_rate": sampleRate,
            "num_channels": numChannels,
            "language_hints": languageHints,
            "enable_speaker_diarization": isSpeakerDiarizationEnabled,
            "enable_endpoint_detection": isEndpointDetectionEnabled,
        ]

        if isLanguageHintsStrict {
            dict["language_hints_strict"] = true
        }

        // Build context object
        var contextDict: [String: Any] = [:]

        if !context.general.isEmpty {
            contextDict["general"] = context.general.map { entry in
                ["key": entry.key, "value": entry.value]
            }
        }

        if !context.terms.isEmpty {
            contextDict["terms"] = context.terms
        }

        if let text = context.text, !text.isEmpty {
            contextDict["text"] = text
        }

        if !contextDict.isEmpty {
            dict["context"] = contextDict
        }

        return dict
    }
}
