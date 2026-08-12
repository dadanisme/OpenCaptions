//
//  MacTranscriptionEngineKind.swift
//  OpenCaptions
//
//  The internal transcription-engine descriptor + a small factory that builds the concrete
//  `RealtimeTranscriptionEngine` for a chosen kind. Cloud Soniox (diarized) plus two on-device
//  engines: Parakeet TDT v2 and Nemotron 560 ms.
//
//  User-facing again via the three-way Settings picker (Soniox / Nemotron / Parakeet) —
//  see docs/2026-08-12-macos-transcription-engine-selector.md. `MacTranscriptionViewModel.start()`
//  resolves the selected case straight from `LiveSessionStore.transcriptionEngineKind`.
//

import Foundation

/// A user-selectable transcription engine on macOS.
enum MacTranscriptionEngineKind: String, CaseIterable, Identifiable {
    case soniox
    case parakeet
    case nemotron

    var id: String { rawValue }

    /// Label for the Settings picker.
    var displayName: String {
        switch self {
        case .soniox: return "Soniox (Cloud)"
        case .parakeet: return "Parakeet TDT v2 (On-device)"
        case .nemotron: return "Nemotron 560 ms (On-device)"
        }
    }

    /// On-device engines run a local CoreML model — they need a one-time model download and show
    /// a "Preparing model…" overlay while the model loads at session start. Soniox is cloud.
    var isOnDevice: Bool { self != .soniox }

    /// The model-download manager backing an on-device engine (nil for cloud Soniox).
    @MainActor
    var modelManager: FluidAudioModelManager? {
        switch self {
        case .soniox: return nil
        case .parakeet: return .parakeet
        case .nemotron: return .nemotron
        }
    }
}

/// Builds the concrete engine for a selected kind. Everything downstream in
/// `MacTranscriptionViewModel` talks to the `RealtimeTranscriptionEngine` protocol, so this is
/// the single place engine choice becomes concrete.
enum MacTranscriptionEngineFactory {
    static func make(
        _ kind: MacTranscriptionEngineKind, sonioxConfig: SonioxConfig
    ) -> any RealtimeTranscriptionEngine {
        switch kind {
        case .soniox: return OnlineTranscriberService(config: sonioxConfig)
        case .parakeet: return ParakeetTranscriberService(config: ParakeetEngineConfig())
        case .nemotron: return NemotronTranscriberService(config: NemotronEngineConfig())
        }
    }
}
