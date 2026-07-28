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

    struct Context: Sendable {
        let general: [GeneralEntry]
        let terms: [String]
        let text: String?

        struct GeneralEntry: Sendable {
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

        // Omit `context` entirely when it carries nothing, rather than sending an
        // empty object.
        let contextDict = context.toDictionary()
        if !contextDict.isEmpty {
            dict["context"] = contextDict
        }

        return dict
    }
}

// MARK: - Context serialization + budget

extension SonioxConfig.Context {

    /// The fixed `general` hints every Soniox request sends — they describe the app
    /// and the expected material, not anything the user maintains. Declared once here
    /// because BOTH Soniox paths need them: the live WebSocket config
    /// (`MacTranscriptionViewModel.makeSonioxConfig`) and the async re-transcription
    /// create request (`SonioxAsyncPostSessionEngine+Requests`), which used to carry
    /// byte-identical copies.
    static let appGeneralEntries: [GeneralEntry] = [
        .init(key: "domain", value: "education/lecture/meeting"),
        .init(key: "intent", value: "Transcription"),
        .init(key: "app_name", value: "Open Captions"),
    ]

    /// Soniox caps the whole `context` object; exceeding it fails the REQUEST, not
    /// just the hints — live, that means the WebSocket never transcribes anything.
    /// `VocabularyStore` clamps to this before either path builds a config, so an
    /// over-long vocabulary degrades (dropped terms) instead of breaking the session.
    /// See https://soniox.com/docs/api-reference/stt/websocket-api.
    static let characterLimit = 10_000

    /// The `context` object as JSON, or `[:]` when it carries nothing. Each field is
    /// omitted while empty so an all-empty context serializes away entirely.
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]

        if !general.isEmpty {
            dict["general"] = general.map { ["key": $0.key, "value": $0.value] }
        }

        if !terms.isEmpty {
            dict["terms"] = terms
        }

        if let text, !text.isEmpty {
            dict["text"] = text
        }

        return dict
    }

    /// Length of this context measured as Soniox receives it — the serialized JSON.
    /// Serializing (rather than summing the parts) counts the braces, quotes, and
    /// escapes that go on the wire too, so the number over-states the raw content by
    /// that envelope: clamping against it stays on the safe side of the cap.
    ///
    /// Counted in UNICODE SCALARS, not `String.count`. Swift's `count` is grapheme
    /// clusters, and a grapheme can be many scalars — decomposed diacritics ("e" +
    /// combining acute), or an emoji ZWJ sequence. Since Soniox's cap is not
    /// documented as grapheme-based, counting the larger unit keeps the measure
    /// conservative for such text. For ASCII and for all three of this app's language
    /// hints (id/en/ar) in normal form the two units are identical, so ordinary
    /// vocabularies are unaffected.
    var characterCount: Int {
        let dict = toDictionary()
        guard !dict.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return 0
        }
        return json.unicodeScalars.count
    }

    /// Whether this context is within Soniox's cap.
    var fitsCharacterLimit: Bool { characterCount <= Self.characterLimit }
}
