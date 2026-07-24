//
//  FeatureFlag.swift
//  OpenCaptions
//
//  Type-safe catalog of remotely-togglable features for the macOS app. Each
//  case's `rawValue` is the key inside the Firestore `config/featureFlags` doc's
//  `flags` map, and `defaultValue` is the compile-time fallback used before the
//  remote value arrives (cold start, offline, or a flag the backend isn't
//  managing). See FeatureFlagService and docs/2026-07-06-macos-firestore-share.md.
//
//  The Mac uses its own `Mac_`-prefixed flag keys so features can be toggled
//  independently (e.g. sharing reads `Mac_session_sharing`). The Mac target only
//  ships the flags relevant to
//  its feature set — currently sharing, session playback, and mixed-source AEC.
//

import Foundation

/// A single remotely-controllable feature toggle for the macOS app.
enum FeatureFlag: String {
    /// Shareable public-link "Share Session" feature: live Firestore sync,
    /// finished-session sharing, and password protection. Gates every share
    /// affordance (live share button, "Copy Share Link"/password menu items) and
    /// kills all Firestore share writes when off. Turning it off mid-session
    /// gracefully seals a session that was live-syncing to `ended` (one final
    /// write) then stops.
    case sessionSharing = "Mac_session_sharing"

    /// Session-audio recording + synced transcript playback: captures each
    /// session's audio to a local `.m4a` and shows a player (with transcript
    /// highlighting) on the saved-session detail screen. Gates both the recorder
    /// (no new audio is captured when off) and the player bar (hidden when off).
    /// Flipping it off mid-session tears down the in-progress recording so nothing
    /// half-recorded is kept. Also gated by a local per-device Settings toggle.
    case sessionPlayback = "Mac_session_playback"

    /// Post-session re-transcription: re-processes a saved session's audio
    /// with a higher-accuracy engine (on-device Parakeet TDT v2, or cloud Soniox
    /// async). Master rollout switch — gates the "Re-transcribe" menu on the saved-
    /// session detail screen; also gated by a local per-device Settings toggle.
    /// Defaults OFF so the feature ships dark and is enabled remotely when ready.
    case postSessionRetranscription = "Mac_post_session_retranscription"

    /// Software acoustic echo cancellation for the "Microphone + System Audio"
    /// mixed source (`OpenCaptionsAEC`, Speex-backed). Gates whether the
    /// canceller is built at session start (off → the mix stays an uncancelled
    /// plain sum, the existing `aec == nil` fallback). Flipping it off mid-session
    /// releases a running canceller so it falls back to plain sum, giving us a
    /// remote escape hatch if the canceller regresses in the field. Only affects
    /// the mixed source — mic-only and system-only capture never build an AEC.
    case aecEnabled = "Mac_aec_enabled"

    /// Import audio & video files for transcription: a file-picker + File-menu
    /// entry point that ingests an existing recording, normalizes its audio to the
    /// app's canonical `.m4a`, and runs it through the post-session transcription
    /// pipeline to produce a saved session (transcript + summary). Gates both entry
    /// points (the toolbar button + the "Import Audio or Video…" command). Defaults
    /// OFF so the feature ships dark and is enabled remotely when ready.
    case fileImport = "Mac_file_import"

    /// Compile-time fallback. Used when the remote `flags` map has no entry for
    /// this flag (first launch, offline, malformed value, or backend not yet
    /// managing it). Keep these conservative — a flag should ship in the state
    /// it would have without any remote configuration.
    var defaultValue: Bool {
        switch self {
        case .sessionSharing: return true
        case .sessionPlayback: return true
        case .postSessionRetranscription: return false
        case .aecEnabled: return true
        case .fileImport: return false
        }
    }
}
