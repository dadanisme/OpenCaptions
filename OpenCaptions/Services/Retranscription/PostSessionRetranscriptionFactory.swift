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
    /// On-device Apple Speech `SpeechAnalyzer` (macOS 26+) — offline, English-only, no
    /// diarization.
    case appleSpeech
    /// Cloud Soniox `stt-async-v5` — diarized, multi-language.
    case soniox
    /// On-device Apple Core AI Parakeet TDT — offline, English-only, no diarization,
    /// macOS 27+ only (see `CoreAIPluginLoader`). Batch/post-session ONLY: Core AI's
    /// export has no streaming path, so this never appears in the LIVE picker
    /// (`MacTranscriptionEngineKind`) — see `LiveSessionStore.retranscriptionEngineKind`
    /// for why re-transcription needed its own, independent engine choice once this
    /// case existed. Real transcription via coreai-kit now runs (#47).
    case coreAIParakeet
    /// On-device Apple Core AI Nemotron 3.5 ASR Streaming — offline, no diarization,
    /// macOS 27+ only. Unlike `.coreAIParakeet`, this model is genuinely streaming
    /// (cache-aware KV/conv state, no fixed encoder bucket), so it's ALSO reachable
    /// from the LIVE picker (`MacTranscriptionEngineKind.coreAINemotron`) — see
    /// docs/2026-08-12-macos-coreai-nemotron-streaming.md (issue #55).
    case coreAINemotron

    var id: String { rawValue }

    /// Menu label.
    var displayName: String {
        switch self {
        case .parakeet: return "Offline (Parakeet)"
        case .nemotron: return "Offline (Nemotron)"
        case .appleSpeech: return "Offline (Apple Speech)"
        case .soniox: return "Cloud (Soniox)"
        case .coreAIParakeet: return "Offline (Parakeet, Core AI)"
        case .coreAINemotron: return "Offline (Nemotron 3.5, Core AI)"
        }
    }

    /// SF Symbol shown next to the menu item.
    var systemImage: String {
        switch self {
        case .parakeet, .nemotron, .appleSpeech, .coreAIParakeet, .coreAINemotron: return "cpu"
        case .soniox: return "cloud"
        }
    }

    /// Whether re-transcription with this engine yields per-speaker labels.
    var supportsDiarization: Bool { self == .soniox }

    /// Whether this engine runs on-device (no diarization, no upload) vs. cloud.
    var isOnDevice: Bool { self != .soniox }

    /// Whether this engine's on-device model is already downloaded. Always `true`
    /// for cloud Soniox, which has no model. `@MainActor`-isolated because the
    /// `.appleSpeech` branch reads the cached status off the `@MainActor` singleton —
    /// `AssetInventory` has no synchronous check, unlike FluidAudio's file-existence one.
    /// All 3 call sites (`RetranscriptionManager`, `FileImportManager`,
    /// `MacSessionDetailView+Retranscription`) are already `@MainActor`-isolated.
    @MainActor
    var isModelDownloaded: Bool {
        switch self {
        case .parakeet: return FluidAudioModelLoader.isParakeetDownloaded()
        case .nemotron: return FluidAudioModelLoader.isNemotronDownloaded()
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechModelManager.shared.status == .ready
            }
            return false
        case .soniox: return true
        // The Parakeet-via-Core-AI plugin downloads/loads lazily on first use, with no
        // separate Settings download step (batch-only, so there's no live-session
        // fail-fast reason to pre-flight it) — see the case's doc comment.
        case .coreAIParakeet: return true
        case .coreAINemotron: return CoreAIPluginLoader.isNemotronModelDownloaded()
        }
    }

    /// Cases to actually offer in a picker — unlike `allCases`, excludes
    /// `.coreAIParakeet`/`.coreAINemotron` unless `CoreAIPluginLoader` reports the
    /// plugin loadable (macOS 27+ AND the dylib is embedded), and excludes `.appleSpeech`
    /// below macOS 26 for the same reason `MacTranscriptionEngineKind.allCases` does.
    /// Below their respective floors, none of the three has any trace anywhere in the UI.
    static var availableCases: [RetranscriptionEngineKind] {
        allCases.filter { kind in
            switch kind {
            case .coreAIParakeet, .coreAINemotron: return CoreAIPluginLoader.isAvailable
            case .appleSpeech:
                if #available(macOS 26.0, *) { return true }
                return false
            default: return true
            }
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
        case .appleSpeech:
            // The `.appleSpeech` case exists at compile time regardless of OS, so Swift's
            // exhaustiveness check requires a branch here unconditionally; the stale-selection
            // fallback in `LiveSessionStore.transcriptionEngineKind` means this `else` is only
            // ever reached in theory (a downgraded OS after the selection was made).
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerPostSessionEngine()
            }
            return SonioxAsyncPostSessionEngine(
                context: VocabularyStore.shared.sonioxContext(userName: userName)
            )
        case .soniox:
            return SonioxAsyncPostSessionEngine(
                context: VocabularyStore.shared.sonioxContext(userName: userName)
            )
        case .coreAIParakeet: return CoreAIParakeetPostSessionEngine()
        case .coreAINemotron: return CoreAINemotronPostSessionEngine()
        }
    }
}
