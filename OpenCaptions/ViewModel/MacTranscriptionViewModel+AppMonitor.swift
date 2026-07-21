//
//  MacTranscriptionViewModel+AppMonitor.swift
//  OgmoMac
//
//  Owns the lifecycle of the source-app attribution monitor
//  (`SystemAudioActivityMonitor`). The monitor only runs when the current capture
//  source includes system audio — mic-only sessions have no app to attribute — so
//  these helpers start it at `start()`, tear it down on stop/discard/failure, and
//  reconcile it across a live source swap. See
//  docs/2026-07-07-macos-source-app-attribution.md.
//

import Foundation

extension MacTranscriptionViewModel {

    /// Starts the activity monitor when the current source captures system audio.
    /// Anchored to `sessionStart` so samples share the line-timestamp clock.
    @MainActor
    func startAppMonitorIfNeeded() {
        guard currentSource.capturesSystemAudio, appMonitor == nil else { return }
        let monitor = SystemAudioActivityMonitor()
        monitor.start(anchor: sessionStart)
        appMonitor = monitor
    }

    @MainActor
    func stopAppMonitor() {
        appMonitor?.stop()
        appMonitor = nil
    }

    /// After a live source swap, start the monitor when the new source captures
    /// system audio, or tear it down when it no longer does. Lines committed
    /// before a mic→system swap correctly get no app (no samples cover them).
    @MainActor
    func reconcileAppMonitor() {
        if currentSource.capturesSystemAudio {
            startAppMonitorIfNeeded()
        } else {
            stopAppMonitor()
        }
    }
}
