//
//  SessionAudioRecorder.swift
//  OpenCaptions
//
//  Writes the live 16 kHz mono Float32 stream (the exact PCM sent to Soniox)
//  to a compressed AAC `.m4a` for later playback.
//

import AVFoundation
import Foundation

/// Records a session's audio to a compressed AAC `.m4a`.
///
/// A plain class (not an actor): `append` is called synchronously from the
/// detached capture loop in `MacTranscriptionViewModel.sendData()`, so an actor
/// would force an async hop dragging a non-Sendable `AVAudioPCMBuffer` across
/// isolation. An `NSLock` serializes `append` against `close`, so a late frame
/// from a draining task after teardown is a safe no-op.
final class SessionAudioRecorder {
    let fileName: String
    let url: URL

    private var file: AVAudioFile?
    /// Total frames written. Only used to auto-delete an empty recording on close.
    private var samplesWritten: AVAudioFramePosition = 0
    private var closed = false
    private let lock = NSLock()
    /// Lazily-built fallback converter, used only if a source ever emits a buffer
    /// whose format differs from the file's processing format. Cached per input.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// The canonical session-audio sample rate (16 kHz mono). Shared with imported-
    /// media transcoding (`MediaAudioExtractor`) so live and imported audio match.
    static let sampleRate = 16_000

    /// The canonical AAC-LC encoding settings for a session `.m4a` (16 kHz, mono,
    /// 32 kbps). `MediaAudioExtractor` reuses this exact dict for its `AVAssetWriter`
    /// so a recorded and an imported file are byte-format-identical and can't drift.
    static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    /// Opens the AAC file for writing. Returns nil on failure — recording then
    /// proceeds audio-less (non-fatal; transcription is unaffected).
    init?(fileName: String) {
        self.fileName = fileName
        self.url = SessionAudioStore.url(for: fileName)
        guard let file = try? AVAudioFile(
            forWriting: url, settings: Self.aacSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false) else {
            return nil
        }
        self.file = file
    }

    /// Appends one captured buffer verbatim. Frames are written back-to-back with
    /// NO padding, so the file is byte-for-byte the audio stream sent to Soniox —
    /// the recording's playback position therefore equals Soniox's audio-stream
    /// position, which is exactly what a line's `start_ms` references (so seeking to
    /// a line needs no offset, and pauses stay in sync because both the recording
    /// and Soniox simply stop while paused). `write(from:)` RAISES (not throws) on a
    /// format mismatch, so coerce to the file's processing format first — all
    /// sources emit the same 16 kHz mono Float32 (fast path), but convert
    /// defensively if one ever differs, skipping rather than crashing.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let file else { return }
        let writeBuffer: AVAudioPCMBuffer
        if buffer.format == file.processingFormat {
            writeBuffer = buffer
        } else if let converted = converted(buffer, to: file.processingFormat) {
            writeBuffer = converted
        } else {
            return
        }
        if (try? file.write(from: writeBuffer)) != nil {
            samplesWritten += AVAudioFramePosition(writeBuffer.frameLength)
        }
    }

    /// Finalizes (or discards) the recording. One-shot and idempotent, so a
    /// `failSession()` → `stop()` double-close is safe. Auto-deletes an empty
    /// file (nothing was ever written) regardless of `deletingFile`.
    func close(deletingFile: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let wroteNothing = samplesWritten == 0
        file = nil  // ARC finalizes the AAC moov atom → playable file
        if deletingFile || wroteNothing {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Converts a mismatched-format buffer to the file's processing format,
    /// caching the converter per input format. Caller must hold `lock`.
    private func converted(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        guard let converter,
              let out = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1)
        else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
