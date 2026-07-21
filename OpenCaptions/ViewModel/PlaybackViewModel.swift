//
//  PlaybackViewModel.swift
//  OgmoMac
//
//  Drives audio playback for a saved session's recording and exposes the
//  playhead so `MacSessionDetailView` can highlight/scroll the active transcript
//  line. Wraps `AVAudioPlayer` with a ~10 Hz Task-based ticker (no delegate, so
//  no NSObject conformance is needed).
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackViewModel {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Whether a playable recording is loaded. Observed (unlike `player`, which is
    /// `@ObservationIgnored`) so the player bar re-evaluates and appears after the
    /// async `load()` completes.
    private(set) var isLoaded = false
    /// True while the user drags the scrubber; suspends ticker-driven updates so
    /// the thumb doesn't fight the drag.
    var isScrubbing = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickerTask: Task<Void, Never>?

    /// Whether there's a playable recording — gates the player bar's visibility.
    var isAvailable: Bool { isLoaded }
    /// Current playhead in milliseconds, for matching against line `startMs`.
    var currentMs: Int { Int(currentTime * 1000) }

    /// Loads the audio for a session filename. Any failure (nil filename, missing
    /// or unplayable file — e.g. a partial crash file) leaves the player nil so the
    /// UI hides the player bar. Safe to call repeatedly (resets prior state).
    func load(fileName: String?) {
        stop()
        player = nil
        isLoaded = false
        currentTime = 0
        duration = 0
        guard let fileName else { return }
        let url = SessionAudioStore.url(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let loaded = try? AVAudioPlayer(contentsOf: url) else { return }
        loaded.prepareToPlay()
        player = loaded
        duration = loaded.duration
        isLoaded = true
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        // Restart from the top when parked at the end.
        if currentTime >= duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else { return }
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    /// Seeks to a transcript line's `startMs` (used by tap-to-seek).
    func seek(toMs ms: Int) {
        seek(to: TimeInterval(ms) / 1000)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Stops playback and tears down the ticker. Called by `load` and on the
    /// detail view's disappearance.
    func stop() {
        player?.stop()
        isPlaying = false
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func tick() {
        guard let player, !isScrubbing else { return }
        if player.isPlaying {
            currentTime = player.currentTime
        } else {
            // Reached the end of the recording.
            isPlaying = false
            currentTime = duration
            stopTicker()
        }
    }

    // No deinit-based teardown needed: the ticker captures `self` weakly, so once
    // this view model deallocates the loop's `guard let self` ends it within one
    // tick. `stop()` (called from `load` and the view's `onDisappear`) covers the
    // normal path.
}
