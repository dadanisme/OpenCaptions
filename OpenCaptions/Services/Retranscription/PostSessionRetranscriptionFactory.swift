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
    /// On-device FluidAudio Nemotron 560 ms — offline, English-only, no diarization.
    case nemotron
    /// Cloud Soniox `stt-async-v5` — diarized, multi-language.
    case soniox

    var id: String { rawValue }

    /// Menu label.
    var displayName: String {
        switch self {
        case .parakeet: return "Offline (Parakeet)"
        case .nemotron: return "Offline (Nemotron)"
        case .soniox: return "Cloud (Soniox)"
        }
    }

    /// SF Symbol shown next to the menu item.
    var systemImage: String {
        switch self {
        case .parakeet, .nemotron: return "cpu"
        case .soniox: return "cloud"
        }
    }

    /// Whether re-transcription with this engine yields per-speaker labels.
    var supportsDiarization: Bool { self == .soniox }

    /// Whether this engine runs on-device (no diarization, no upload) vs. cloud.
    var isOnDevice: Bool { self != .soniox }

    /// Whether this engine's on-device model is already downloaded. Always `true`
    /// for cloud Soniox, which has no model.
    var isModelDownloaded: Bool {
        switch self {
        case .parakeet: return FluidAudioModelLoader.isParakeetDownloaded()
        case .nemotron: return FluidAudioModelLoader.isNemotronDownloaded()
        case .soniox: return true
        }
    }

    /// Re-transcription doesn't offer its own engine choice — it FOLLOWS the global
    /// Transcription Engine selection (Settings → General). Single source of truth
    /// for both the manual menu and the automatic path.
    static var forCurrentMode: RetranscriptionEngineKind {
        switch LiveSessionStore.transcriptionEngineKind {
        case .soniox: return .soniox
        case .parakeet: return .parakeet
        case .nemotron: return .nemotron
        }
    }
}

enum PostSessionRetranscriptionFactory {
    /// Builds the engine for `kind`.
    ///
    /// Soniox is handed the same biasing context a live session would use — the user's
    /// custom vocabulary plus the app's built-ins plus `userName` — resolved HERE
    /// because `VocabularyStore` is main-actor-isolated while the engine itself runs
    /// off it. The on-device engines take none: FluidAudio's term-biasing hook exists
    /// only on the live sliding-window/streaming managers, not the batch paths these
    /// use, so offline re-transcription is unbiased (see
    /// `docs/2026-07-28-macos-custom-vocabulary.md`).
    @MainActor
    static func make(_ kind: RetranscriptionEngineKind, userName: String?) -> any PostSessionTranscriptionEngine {
        switch kind {
        case .parakeet: return ParakeetPostSessionEngine()
        case .nemotron: return NemotronPostSessionEngine()
        case .soniox:
            return SonioxAsyncPostSessionEngine(
                context: VocabularyStore.shared.sonioxContext(userName: userName)
            )
        }
    }
}
