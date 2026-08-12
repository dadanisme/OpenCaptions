//
//  LiveSessionStore+TranscriptionEngine.swift
//  OpenCaptions
//
//  The transcription engine selection (Soniox / Nemotron / Parakeet / Apple Speech) —
//  the global Settings preference that replaced the old binary Offline Mode
//  toggle. See docs/2026-08-12-macos-transcription-engine-selector.md and
//  docs/2026-08-12-macos-speechanalyzer-engine.md.
//

import Foundation

extension LiveSessionStore {

    /// UserDefaults key (String) for the transcription engine selection —
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

    /// The current transcription engine selection, decoded from
    /// `transcriptionEngineKindKey`. Falls back to `.soniox` for an unset/invalid
    /// raw value so a corrupted default never silently routes a session on-device.
    /// Also falls back to `.soniox` when the decoded value is `.appleSpeech` but the OS has
    /// since dropped below macOS 26 (a previously-valid selection becoming stale — macOS
    /// doesn't downgrade in normal use, but this is the same defensive fallback as the
    /// unset/invalid case above, and it's the single choke point both live-session start
    /// (`MacTranscriptionViewModel.start()`) and `RetranscriptionEngineKind.forCurrentMode`
    /// read through, so neither needs its own separate fix).
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
}
