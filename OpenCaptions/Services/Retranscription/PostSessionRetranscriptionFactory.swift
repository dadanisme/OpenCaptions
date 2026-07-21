//
//  PostSessionRetranscriptionFactory.swift
//  OpenCaptions
//
//  Selects a `PostSessionTranscriptionEngine` for re-transcribing a saved session.
//  Mirrors the live `MacTranscriptionEngineFactory`. Adding a provider = add a
//  `RetranscriptionEngineKind` case and a factory branch. See issue #245.
//

import Foundation

/// The available post-session (re-transcription) engines.
enum RetranscriptionEngineKind: String, CaseIterable, Identifiable {
    /// On-device FluidAudio Parakeet TDT v2 — offline, free, English-only, no diarization.
    case parakeet
    /// Cloud Soniox `stt-async-v5` — diarized, multi-language, billable.
    case soniox

    var id: String { rawValue }

    /// Menu label.
    var displayName: String {
        switch self {
        case .parakeet: return "Offline (Parakeet)"
        case .soniox: return "Cloud (Soniox)"
        }
    }

    /// SF Symbol shown next to the menu item.
    var systemImage: String {
        switch self {
        case .parakeet: return "cpu"
        case .soniox: return "cloud"
        }
    }

    /// Whether this engine bills minutes (cloud) vs. runs free (on-device).
    var isMetered: Bool { self == .soniox }

    /// Whether re-transcription with this engine yields per-speaker labels.
    var supportsDiarization: Bool { self == .soniox }

    /// Re-transcription doesn't offer its own engine choice — it FOLLOWS Offline Mode:
    /// on-device Parakeet when Offline Mode is on, cloud Soniox when it's off. Single
    /// source of truth for both the manual menu and the automatic path.
    static var forCurrentMode: RetranscriptionEngineKind {
        UserDefaults.standard.bool(forKey: LiveSessionStore.offlineModeKey) ? .parakeet : .soniox
    }
}

enum PostSessionRetranscriptionFactory {
    /// Builds the engine for `kind`. `userName` biases Soniox's context terms.
    static func make(_ kind: RetranscriptionEngineKind, userName: String?) -> any PostSessionTranscriptionEngine {
        switch kind {
        case .parakeet: return ParakeetPostSessionEngine()
        case .soniox: return SonioxAsyncPostSessionEngine(userName: userName)
        }
    }
}
