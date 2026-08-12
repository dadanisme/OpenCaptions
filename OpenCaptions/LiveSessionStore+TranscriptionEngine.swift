//
//  LiveSessionStore+TranscriptionEngine.swift
//  OpenCaptions
//
//  The LIVE transcription engine selection (Soniox / Nemotron / Parakeet / Apple
//  Speech, plus Core AI Nemotron on macOS 27+) — the global Settings preference
//  that replaced the old binary Offline Mode toggle. See
//  docs/2026-08-12-macos-transcription-engine-selector.md,
//  docs/2026-08-12-macos-speechanalyzer-engine.md, and
//  docs/2026-08-12-macos-coreai-nemotron-streaming.md. Also holds the independent
//  RE-TRANSCRIPTION (batch/post-session/import) engine override added in #47 —
//  see the "Re-transcription (batch) engine" section below.
//

import Foundation

extension LiveSessionStore {

    /// UserDefaults key (String) for the live transcription engine selection —
    /// `MacTranscriptionEngineKind.rawValue`. Read at session start by
    /// `MacTranscriptionViewModel.start`, by `MacSessionDetailView` to gate cloud
    /// summary generation, and by `RetranscriptionEngineKind.forCurrentMode` for
    /// post-session/import. Bound to the picker in Settings → General. Default
    /// `"soniox"` (registered in `OpenCaptionsApp`). Replaces the old binary
    /// `offlineModeKey` — see `migrateOfflineModeKeyIfNeeded()` below. `nonisolated`
    /// so the nonisolated members below (and cross-file readers like
    /// `RetranscriptionEngineKind.forCurrentMode`) can reference it without a
    /// Swift 6 strict-concurrency warning — it's an immutable `String` literal
    /// with no actor affinity of its own.
    nonisolated static let transcriptionEngineKindKey = "opencaptions.transcriptionEngine.kind"

    /// The current live transcription engine selection, decoded from
    /// `transcriptionEngineKindKey`. Falls back to `.soniox` for an unset/invalid
    /// raw value so a corrupted default never silently routes a session on-device.
    /// Also falls back to `.soniox` when the decoded value is `.appleSpeech`/`.coreAINemotron`
    /// but the OS/plugin has since dropped below their floor (a previously-valid selection
    /// becoming stale — macOS doesn't downgrade in normal use, but this is the same defensive
    /// fallback as the unset/invalid case above, and it's the single choke point both
    /// live-session start (`MacTranscriptionViewModel.start()`) and
    /// `RetranscriptionEngineKind.forCurrentMode` read through, so neither needs its own
    /// separate fix).
    /// `nonisolated`: a plain `UserDefaults` read with no MainActor state involved,
    /// so it stays callable from the same variety of contexts the old raw
    /// `UserDefaults.standard.bool(forKey: offlineModeKey)` read was (e.g.
    /// `RetranscriptionEngineKind.forCurrentMode`, a nonisolated static var).
    nonisolated static var transcriptionEngineKind: MacTranscriptionEngineKind {
        let kind =
            MacTranscriptionEngineKind(
                rawValue: UserDefaults.standard.string(forKey: transcriptionEngineKindKey) ?? ""
            ) ?? .soniox
        if kind == .appleSpeech {
            if #available(macOS 26.0, *) { return kind }
            return .soniox
        }
        if kind == .coreAINemotron {
            if CoreAIPluginLoader.isAvailable { return kind }
            return .soniox
        }
        return kind
    }

    /// One-time migration from the deleted binary `offlineModeKey`
    /// (`"opencaptions.offlineMode.enabled"`) to `transcriptionEngineKindKey`:
    /// `true` → `.nemotron` (the old Offline Mode's sole on-device engine),
    /// `false`/unset → `.soniox`. No-ops once the new key already has a value, so
    /// this is safe to call unconditionally on every launch. Called from
    /// `OpenCaptionsApp.init()` — `nonisolated` since `init()` runs before any
    /// actor context is established.
    nonisolated static func migrateOfflineModeKeyIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "opencaptions.offlineMode.enabled"
        guard defaults.string(forKey: transcriptionEngineKindKey) == nil,
            defaults.object(forKey: legacyKey) != nil
        else { return }
        let wasOffline = defaults.bool(forKey: legacyKey)
        defaults.set(
            (wasOffline ? MacTranscriptionEngineKind.nemotron : .soniox).rawValue,
            forKey: transcriptionEngineKindKey)
        defaults.removeObject(forKey: legacyKey)
    }

    // MARK: - Re-transcription (batch) engine — independent of the live selection

    /// UserDefaults key (String) for an EXPLICIT override of the re-transcription
    /// (post-session/import) engine, independent of `transcriptionEngineKindKey`
    /// above. Empty/absent (the default for every existing user) means "follow the
    /// live Transcription Engine selection" — the same behavior `RetranscriptionEngineKind
    /// .forCurrentMode` used to hardcode before #47. An override only becomes
    /// reachable through UI once `RetranscriptionEngineKind.availableCases` offers
    /// something the live picker can't (macOS 27+'s Core AI Parakeet, batch-only —
    /// see that case's doc comment) — until then every user's effective behavior is
    /// byte-for-byte what `forCurrentMode` already did, override or not.
    nonisolated static let retranscriptionEngineOverrideKey = "opencaptions.retranscriptionEngine.override"

    /// The explicit override, or `nil` if unset, unparseable, or no longer available
    /// (e.g. a stored `.coreAIParakeet` override read back on a machine where the
    /// plugin isn't loadable) — the last case matters because without it, a user who
    /// set the override on one Mac and copies preferences to another would get a
    /// silently "stuck" selection instead of falling back to the live one.
    nonisolated static var retranscriptionEngineOverride: RetranscriptionEngineKind? {
        guard let raw = UserDefaults.standard.string(forKey: retranscriptionEngineOverrideKey),
            let kind = RetranscriptionEngineKind(rawValue: raw),
            RetranscriptionEngineKind.availableCases.contains(kind)
        else { return nil }
        return kind
    }

    /// The effective re-transcription (post-session/import) engine: the explicit
    /// override above if one is set and still available, else derived from the live
    /// `transcriptionEngineKind` — exactly the mapping `RetranscriptionEngineKind
    /// .forCurrentMode` used to perform unconditionally. Single source of truth for
    /// the manual re-transcribe menu, automatic re-transcription, and file import.
    nonisolated static var retranscriptionEngineKind: RetranscriptionEngineKind {
        if let override = retranscriptionEngineOverride { return override }
        switch transcriptionEngineKind {
        case .soniox: return .soniox
        case .parakeet: return .parakeet
        case .nemotron: return .nemotron
        case .appleSpeech: return .appleSpeech
        case .coreAINemotron: return .coreAINemotron
        }
    }
}
