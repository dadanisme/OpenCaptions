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
    /// On-device Apple Core AI Parakeet TDT — offline, English-only, no diarization,
    /// macOS 27+ only (see `CoreAIPluginLoader`). Batch/post-session ONLY: Core AI's
    /// export has no streaming path, so this never appears in the LIVE picker
    /// (`MacTranscriptionEngineKind`) — see `LiveSessionStore.retranscriptionEngineKind`
    /// for why re-transcription needed its own, independent engine choice once this
    /// case existed. Currently a stub (#47) — real model wiring is a follow-up.
    case coreAIParakeet

    var id: String { rawValue }

    /// Menu label.
    var displayName: String {
        switch self {
        case .parakeet: return "Offline (Parakeet)"
        case .nemotron: return "Offline (Nemotron)"
        case .soniox: return "Cloud (Soniox)"
        case .coreAIParakeet: return "Offline (Parakeet, Core AI)"
        }
    }

    /// SF Symbol shown next to the menu item.
    var systemImage: String {
        switch self {
        case .parakeet, .nemotron, .coreAIParakeet: return "cpu"
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
        // Stub has no model of its own yet to download — see the case's doc comment.
        case .coreAIParakeet: return true
        }
    }

    /// Cases to actually offer in a picker — unlike `allCases`, excludes
    /// `.coreAIParakeet` unless `CoreAIPluginLoader` reports the plugin loadable
    /// (macOS 27+ AND the dylib is embedded). Below that, `.coreAIParakeet` has NO
    /// trace anywhere in the UI, per #47's own requirement.
    static var availableCases: [RetranscriptionEngineKind] {
        allCases.filter { $0 != .coreAIParakeet || CoreAIPluginLoader.isAvailable }
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
        case .coreAIParakeet: return CoreAIParakeetPostSessionEngine()
        }
    }
}
