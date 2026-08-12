//
//  MacTranscriptionEngineKind.swift
//  OpenCaptions
//
//  The internal transcription-engine descriptor + a small factory that builds the concrete
//  `RealtimeTranscriptionEngine` for a chosen kind. Cloud Soniox (diarized), two FluidAudio
//  on-device engines (Parakeet TDT v2, Nemotron 560 ms), Apple Speech's `SpeechAnalyzer`
//  (macOS 26+ only, #53), and Apple Core AI's Nemotron 3.5 streaming ASR (macOS 27+ only, #55).
//
//  User-facing again via the Settings picker — see
//  docs/2026-08-12-macos-transcription-engine-selector.md,
//  docs/2026-08-12-macos-speechanalyzer-engine.md, and
//  docs/2026-08-12-macos-coreai-nemotron-streaming.md. `MacTranscriptionViewModel.start()`
//  resolves the selected case straight from `LiveSessionStore.transcriptionEngineKind`.
//

import Foundation

/// A user-selectable transcription engine on macOS.
enum MacTranscriptionEngineKind: String, Identifiable {
    case soniox
    case parakeet
    case nemotron
    /// Apple's `Speech` framework `SpeechAnalyzer`/`SpeechTranscriber` (WWDC25) — macOS 26+ only.
    case appleSpeech
    /// Apple Core AI Nemotron 3.5 ASR Streaming — offline, no diarization, no term biasing,
    /// macOS 27+ only (see `CoreAIPluginLoader.isAvailable`). Unlike the batch-only
    /// `RetranscriptionEngineKind.coreAIParakeet`, this model is genuinely streaming, so it's
    /// reachable live — see `allCases` for the gating and
    /// docs/2026-08-12-macos-coreai-nemotron-streaming.md for why.
    case coreAINemotron

    /// Manual `CaseIterable` equivalent (not synthesized): excludes `.appleSpeech` below macOS 26
    /// and `.coreAINemotron` unless `CoreAIPluginLoader` reports the plugin loadable (macOS 27+
    /// AND the dylib is embedded) — below their respective floors, the underlying API doesn't
    /// exist. Consumers (the Settings picker's `ForEach`) need no OS-version logic of their own
    /// as a result.
    static var allCases: [MacTranscriptionEngineKind] {
        var cases: [MacTranscriptionEngineKind] = [.soniox, .parakeet, .nemotron]
        if #available(macOS 26.0, *) {
            cases.append(.appleSpeech)
        }
        if CoreAIPluginLoader.isAvailable {
            cases.append(.coreAINemotron)
        }
        return cases
    }

    var id: String { rawValue }

    /// Label for the Settings picker.
    var displayName: String {
        switch self {
        case .soniox: return "Soniox (Cloud)"
        case .parakeet: return "Parakeet TDT v2 (On-device)"
        case .nemotron: return "Nemotron 560 ms (On-device)"
        case .appleSpeech: return "Apple Speech (On-device)"
        case .coreAINemotron: return "Nemotron 3.5 Streaming (Core AI, On-device)"
        }
    }

    /// On-device engines run a local model — they need a one-time model download and show
    /// a "Preparing model…" overlay while the model loads at session start. Soniox is cloud.
    var isOnDevice: Bool { self != .soniox }

    /// The model-download manager backing an on-device engine (nil for cloud Soniox, and for
    /// `.appleSpeech` below macOS 26 — see `LiveSessionStore.transcriptionEngineKind`'s
    /// stale-selection fallback, which prevents that combination from being selected at all).
    @MainActor
    var modelManager: (any OnDeviceEngineModelManaging)? {
        switch self {
        case .soniox: return nil
        case .parakeet: return FluidAudioModelManager.parakeet
        case .nemotron: return FluidAudioModelManager.nemotron
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechModelManager.shared
            }
            return nil
        case .coreAINemotron: return CoreAINemotronModelManager.shared
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
        case .appleSpeech:
            // The `.appleSpeech` case exists at compile time regardless of OS, so Swift's
            // exhaustiveness check requires a branch here unconditionally; the stale-selection
            // fallback in `LiveSessionStore.transcriptionEngineKind` means this `else` is only
            // ever reached in theory (a downgraded OS after the selection was made).
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerTranscriberService()
            }
            return OnlineTranscriberService(config: sonioxConfig)
        case .coreAINemotron: return CoreAINemotronTranscriberService()
        }
    }
}
