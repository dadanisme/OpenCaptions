//
//  MixedAudioCaptureService+Stats.swift
//  OpenCaptions
//
//  Mix-alignment instrumentation for the "Microphone + System Audio" source.
//  Accumulates cheap per-callback counters on the mic render thread and flushes a
//  one-line summary to Console (~1 s) so the two quantities that are NOT knowable
//  from source can be measured on device and used to tune
//  `systemRefCushionSamples`:
//
//    1. The mic input tap buffer size — `installTap(bufferSize: 0)` is a hint macOS
//       may coerce to anywhere from ~10 ms to ~100 ms; the `n=` field reports it.
//    2. The residual system-vs-mic lag — the `ring occupancy` field (sampled BEFORE
//       the pacer trims) shows the startup seed collapse to ~cushion, and
//       `underrun` flags whether the cushion is too small (a gapped reference makes
//       the Speex canceller diverge, so this must stay near 0 %).
//
//  See docs/2026-07-16-macos-mic-system-sync-fix.md.
//

import Foundation
import OSLog

extension MixedAudioCaptureService {

    /// Fold one mic callback into the running window and emit a summary once the
    /// window covers ~1 s of audio. `occupancy` is the ring's fill measured before
    /// the pre-read trim (so the first windows show the seed draining to ~cushion).
    /// Called only from the mic render thread, so the counters need no lock.
    func recordMixStats(n: Int, read: Int, occupancy: Int) {
        statCallbackCount += 1
        statSamplesRequested += n
        statSamplesRead += read
        statOccupancySum += occupancy
        if n < statMinN { statMinN = n }
        if n > statMaxN { statMaxN = n }

        // ~1 s of 16 kHz audio per line — self-pacing regardless of buffer size.
        guard statSamplesRequested >= 16_000, statCallbackCount > 0 else { return }

        let avgN = statSamplesRequested / statCallbackCount
        let occupancyMs = Double(statOccupancySum) / Double(statCallbackCount) / 16.0
        let underrunPct = statSamplesRequested > 0
            ? Double(statSamplesRequested - statSamplesRead) / Double(statSamplesRequested) * 100
            : 0
        let msg = String(
            format: "mix align: n=%ld [%ld…%ld] (%ld ms/callback); ring occupancy=%.1f ms; "
                + "underrun=%.1f%% (cushion=%ld ms)",
            avgN, statMinN, statMaxN, avgN / 16, occupancyMs, underrunPct,
            Self.systemRefCushionSamples / 16
        )
        log.notice("\(msg, privacy: .public)")

        statCallbackCount = 0
        statSamplesRequested = 0
        statSamplesRead = 0
        statOccupancySum = 0
        statMinN = Int.max
        statMaxN = 0
    }
}
