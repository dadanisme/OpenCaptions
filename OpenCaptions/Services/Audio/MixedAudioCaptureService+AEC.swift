//
//  MixedAudioCaptureService+AEC.swift
//  OpenCaptions
//
//  Remote feature-flag control for the mixed-source software echo canceller
//  (`OpenCaptionsAEC`). Lets the team disable AEC from Firestore (`Mac_aec_enabled`)
//  without shipping a build, falling back to the uncancelled plain-sum mix if the
//  canceller regresses in the field (issue #231).
//
//  The gate itself (build-or-skip the OpenCaptionsAEC) lives in `+Mic`'s
//  `configureMicEngine`; this file just keeps `aecEnabled`/`aec` in sync with the
//  remote flag. `setAECEnabled` is the thread-safe seam both the observer and the
//  render/setup paths cross; `observeAECFlag` is the self-re-arming kill switch.
//  Mirrors FirestoreSyncService.observeSessionSharingFlag /
//  MacTranscriptionViewModel.observeAudioFlag. See
//  docs/2026-07-08-macos-aec-feature-flag.md.
//

import Foundation
import Observation

extension MixedAudioCaptureService {

    /// Apply a resolved flag value to the canceller state. Thread-safe (guards
    /// `aecLock`): callable from the main-actor observer, the off-main `start()`
    /// setup, or anywhere else. Turning it OFF releases a running canceller so the
    /// mix immediately falls back to a plain sum (the render thread snapshots `aec`
    /// under the same lock, so the release can't race a `process` call). Turning it
    /// ON only records intent — the canceller is (re)built solely by
    /// `configureMicEngine` at session start, so re-enabling mid-session does NOT
    /// auto-resume cancellation (matches the other Mac kill switches' convention).
    func setAECEnabled(_ enabled: Bool) {
        aecLock.lock()
        defer { aecLock.unlock() }
        aecEnabled = enabled
        if !enabled { aec = nil }
    }

    /// Arms a one-shot `withObservationTracking` on `FeatureFlag.aecEnabled` and
    /// re-arms itself after each change, giving the live session a reaction to
    /// remote flips. Called on the main actor from `makeAudioSource` BEFORE
    /// `start()`, so its initial snapshot sets `aecEnabled` before the off-main
    /// `configureMicEngine` reads it for the build gate.
    ///
    /// `[weak self]` MUST be on the OUTER onChange: `withObservationTracking`
    /// registers the handler with `FeatureFlagService.shared`'s immortal registrar,
    /// so a strong capture would pin this per-session service alive until the flag
    /// next changes (a nested `Task { [weak self] }` would not prevent the outer
    /// closure's strong capture). See the leak note on `observeAudioFlag`.
    @MainActor
    func observeAECFlag() {
        setAECEnabled(FeatureFlagService.shared.isEnabled(.aecEnabled))
        withObservationTracking {
            _ = FeatureFlagService.shared.isEnabled(.aecEnabled)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let enabled = FeatureFlagService.shared.isEnabled(.aecEnabled)
                self.setAECEnabled(enabled)
                // Re-arm only while enabled: once disabled we've released the AEC
                // and don't auto-resume, so there's nothing left to watch.
                if enabled { self.observeAECFlag() }
            }
        }
    }
}
