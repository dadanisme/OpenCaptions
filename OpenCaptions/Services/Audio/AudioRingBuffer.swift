//
//  AudioRingBuffer.swift
//  OpenCaptions
//
//  A bounded, thread-safe FIFO of 16 kHz mono Float32 samples used to realign the
//  asynchronous system-audio stream (Core Audio process tap) to the microphone's
//  capture clock when mixing the two (`MixedAudioCaptureService`). Writes (tap
//  drain task) and reads (mic render thread) genuinely race, so every access is
//  locked. On overflow it DROPS THE OLDEST samples: the mic tap is the pacer, so
//  stale system audio is discarded rather than allowed to accrue unbounded
//  latency — this is what absorbs the mic-vs-tap clock drift, keeping the span
//  handed to the echo canceller aligned with the mic.
//

import Foundation

final class AudioRingBuffer {

    private var storage: [Float]
    private let capacity: Int
    private var head = 0        // index of the oldest buffered sample (next read)
    private var available = 0   // samples currently buffered
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Append `samples`, dropping the oldest to stay within capacity.
    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for i in 0..<samples.count {
            storage[(head + available) % capacity] = base[i]
            if available == capacity {
                head = (head + 1) % capacity   // full → overwrite, advance past the dropped sample
            } else {
                available += 1
            }
        }
    }

    /// Drop the oldest samples so at most `maxAvailable` remain buffered, returning
    /// the occupancy *before* trimming (for the mixer's alignment instrumentation).
    /// The mic pacer calls this before each read to pin the system audio's latency
    /// to a small target (this read's span + a jitter cushion) instead of letting it
    /// sit at whatever the startup seed left in the ring. It's the tight-bound
    /// analogue of the drop-oldest that `write` applies only at full capacity: it
    /// keeps the far-end AEC reference (and the re-added system span, one and the
    /// same buffer) aligned with the fresh mic rather than lagging by hundreds of ms.
    /// Post-#306 (system produced at the mic's rate) the first trim discards the
    /// startup seed and occupancy then holds at the cushion.
    /// See docs/2026-07-16-macos-mic-system-sync-fix.md.
    @discardableResult
    func trim(toMaxAvailable maxAvailable: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let before = available
        let target = max(0, maxAvailable)
        if available > target {
            let drop = available - target
            head = (head + drop) % capacity
            available -= drop
        }
        return before
    }

    /// Pop up to `count` samples into `dest` (which the caller pre-zeroes, so a
    /// shortfall reads as silence). Returns the number actually read.
    @discardableResult
    func read(into dest: UnsafeMutableBufferPointer<Float>, count: Int) -> Int {
        guard let base = dest.baseAddress else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let toRead = min(count, available, dest.count)
        for i in 0..<toRead {
            base[i] = storage[head]
            head = (head + 1) % capacity
        }
        available -= toRead
        return toRead
    }

    /// Drop all buffered samples (called on stop so a new session starts clean).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        head = 0
        available = 0
    }
}
