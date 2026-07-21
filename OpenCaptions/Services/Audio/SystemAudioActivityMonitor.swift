//
//  SystemAudioActivityMonitor.swift
//  OgmoMac
//
//  Option-1 source-app attribution: samples, on a background timer, which apps
//  are currently OUTPUTTING audio (Core Audio process objects whose
//  `kAudioProcessPropertyIsRunningOutput` is set), keyed to the session clock, so
//  the pipeline can later ask "which app was playing during this line's window?".
//
//  This is a HEURISTIC. The system tap is a single global mixdown
//  (`SystemAudioTapCaptureService`), so a line's audio can't be split by app from
//  the stream itself — we correlate its `startMs`/`endMs` against this activity
//  time-series instead. Accurate when one app plays at a time; ambiguous when
//  several overlap. See docs/2026-07-07-macos-source-app-attribution.md.
//
//  Requires macOS 14.4+ (the process-object properties ship with process taps);
//  the whole target deploys to 14.4, so no `@available` guard is needed.
//

import CoreAudio
import Foundation
import OSLog

final class SystemAudioActivityMonitor {

    /// One sample: the session-relative ms it was taken at, and the bundle ids
    /// outputting audio at that instant (OGMO itself excluded).
    private struct Sample {
        let ms: Int
        let bundleIDs: [String]
    }

    /// All timer + `anchor` access happens on this queue; `samples` is additionally
    /// lock-guarded because `dominantApp` reads it from the main actor.
    private let queue = DispatchQueue(label: "com.ogmo.audio-activity-monitor", qos: .utility)
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var timer: DispatchSourceTimer?
    /// Resolved attribution per process object — an app bundle id, or the
    /// `unknownSystemAudio` marker — cached so the PID walk happens once per
    /// process instead of every tick. Queue-confined.
    private var bundleIDCache: [AudioObjectID: String] = [:]

    private let log = Logger(subsystem: "com.muhammadramdan.OgmoMac", category: "AudioActivity")

    /// CFAbsoluteTime anchor matching the view model's `sessionStart`, so sample
    /// ms line up with the line `startMs`/`endMs` stamped from `totalActiveTime`.
    private var anchor: CFAbsoluteTime = 0
    private let ownBundleID = Bundle.main.bundleIdentifier

    /// Sampling cadence. Audio-app changes aren't sub-second critical, so 0.5s
    /// keeps the HAL polling cheap while still catching quick app switches.
    private let interval: TimeInterval = 0.5
    /// Slack added to each side of a line's window when correlating, so short
    /// lines still catch a neighbouring sample.
    private let windowSlackMs = 1000
    /// Hard cap on retained samples (~1h at 0.5s) so a marathon session can't grow
    /// the buffer without bound; oldest are dropped first.
    private let maxSamples = 7200

    // MARK: - Lifecycle

    /// Begin sampling. `anchor` must be the view model's `sessionStart`.
    func start(anchor: CFAbsoluteTime) {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        queue.async { [weak self] in
            self?.anchor = anchor
            self?.installTimer()
        }
    }

    /// Suspend sampling during a soft pause (no audio → no lines to attribute).
    /// The `anchor` is kept so ms stay consistent across the pause.
    func pause() { queue.async { [weak self] in self?.tearDownTimer() } }

    func resume() { queue.async { [weak self] in self?.installTimer() } }

    func stop() {
        queue.async { [weak self] in self?.tearDownTimer() }
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    /// A resumed dispatch source must be cancelled before its last reference
    /// drops, or libdispatch traps. `cancel()` is safe from any thread, and by
    /// deinit no queue block holds `self` strongly, so `timer` isn't racing.
    deinit { timer?.cancel() }

    /// Must run on `queue`.
    private func installTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.sampleNow() }
        timer = source
        source.resume()
    }

    /// Must run on `queue`.
    private func tearDownTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Sampling (on `queue`)

    private func sampleNow() {
        let ms = Int((CFAbsoluteTimeGetCurrent() - anchor) * 1000)
        guard ms >= 0 else { return }
        let active = outputActiveBundleIDs()
        lock.lock()
        samples.append(Sample(ms: ms, bundleIDs: active))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        lock.unlock()
    }

    // MARK: - Query (from the main actor)

    /// The dominant app outputting audio during `[fromMs, toMs]`, or nil if
    /// nothing was playing (→ the line is the user's own mic). "Dominant" = the
    /// bundle id present in the most samples across the window; ties break to the
    /// most recently seen. Falls back to the single nearest sample when the window
    /// is too short to contain one (e.g. a one-word line between two ticks).
    func dominantApp(fromMs: Int, toMs: Int) -> String? {
        lock.lock(); let snapshot = samples; lock.unlock()
        guard !snapshot.isEmpty else { return nil }

        let lo = min(fromMs, toMs) - windowSlackMs
        let hi = max(fromMs, toMs) + windowSlackMs
        var window = snapshot.filter { $0.ms >= lo && $0.ms <= hi }
        if window.isEmpty {
            let mid = (fromMs + toMs) / 2
            if let nearest = snapshot.min(by: { abs($0.ms - mid) < abs($1.ms - mid) }) {
                window = [nearest]
            }
        }

        var counts: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
        for sample in window {
            for id in sample.bundleIDs {
                counts[id, default: 0] += 1
                lastSeen[id] = max(lastSeen[id] ?? 0, sample.ms)
            }
        }
        guard !counts.isEmpty else { return nil }
        // Prefer a NAMED app; the "unknown system audio" marker only wins when it's
        // the sole signal (so a named app playing alongside an unnameable helper
        // still attributes to the app).
        let named = counts.filter { $0.key != SourceAppMarker.unknownSystemAudio }
        let pool = named.isEmpty ? counts : named
        return pool.max { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value < rhs.value
                : (lastSeen[lhs.key] ?? 0) < (lastSeen[rhs.key] ?? 0)
        }?.key
    }

    // MARK: - Core Audio (on `queue`)

    /// Bundle ids of every process currently outputting audio, excluding OGMO.
    /// Runs on `queue`; caches the per-process resolution.
    private func outputActiveBundleIDs() -> [String] {
        guard let processes = try? CoreAudioTapUtils.processObjectList() else { return [] }
        var ids: [String] = []
        for process in processes where CoreAudioTapUtils.isRunningOutput(process) {
            let bundle: String
            if let cached = bundleIDCache[process] {
                bundle = cached
            } else {
                bundle = resolveApp(for: process)
                bundleIDCache[process] = bundle
            }
            guard bundle != ownBundleID else { continue }
            ids.append(bundle)
        }
        return ids
    }

    /// Attribute a process to the owning APP: walk its PID up to the responsible
    /// app (a Chrome/Steam helper → the app), so we get the app's icon rather than
    /// a blank helper icon. When the PID can't be mapped to a nameable app (a
    /// WebKit XPC service under launchd, a FaceTime/system daemon), returns the
    /// `unknownSystemAudio` marker so the line still shows a neutral speaker glyph.
    private func resolveApp(for process: AudioObjectID) -> String {
        let pid = CoreAudioTapUtils.pid(for: process)
        let app = pid.flatMap(AppProcessResolver.appBundleID(forPID:))
        #if DEBUG
        let raw = CoreAudioTapUtils.bundleID(for: process)
        log.debug("audio-out pid=\(pid ?? -1, privacy: .public) raw=\(raw ?? "nil", privacy: .public) app=\(app ?? "nil", privacy: .public)")
        #endif
        return app ?? SourceAppMarker.unknownSystemAudio
    }
}
