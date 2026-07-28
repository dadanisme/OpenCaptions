//
//  PostSessionRetranscriptionFactory.swift
//  OpenCaptions
//
//  Selects a `PostSessionTranscriptionEngine` for re-transcribing a saved session.
//  Mirrors the live `MacTranscriptionEngineFactory`. Adding a provider = add a
//  `RetranscriptionEngineKind` case and a factory branch.
//

import Foundation

/// The available post-session (re-transcription) engines.
enum RetranscriptionEngineKind: String, CaseIterable, Identifiable {
    /// On-device FluidAudio Parakeet TDT v2 — offline, English-only, no diarization.
    case parakeet
    /// Cloud Soniox `stt-async-v5` — diarized, multi-language.
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
    /// Builds the engine for `kind`.
    ///
    /// Soniox is handed the same biasing context a live session would use — the user's
    /// custom vocabulary plus the app's built-ins plus `userName` — resolved HERE
    /// because `VocabularyStore` is main-actor-isolated while the engine itself runs
    /// off it. Parakeet takes none: FluidAudio's term-biasing hook exists only on the
    /// sliding-window streaming manager, not the batch `AsrManager` this path uses, so
    /// offline re-transcription is unbiased (see
    /// `docs/2026-07-28-macos-custom-vocabulary.md`).
    @MainActor
    static func make(_ kind: RetranscriptionEngineKind, userName: String?) -> any PostSessionTranscriptionEngine {
        switch kind {
        case .parakeet: return ParakeetPostSessionEngine()
        case .soniox:
            return SonioxAsyncPostSessionEngine(
                context: VocabularyStore.shared.sonioxContext(userName: userName)
            )
        }
    }
}
