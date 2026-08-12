//
//  CoreAINemotronPostSessionEngine.swift
//  OpenCaptions
//
//  On-device post-session re-transcription via Apple Core AI's Nemotron 3.5 streaming ASR,
//  loaded through CoreAIPluginLoader (see its header for why this needs a dlopen'd sibling
//  package rather than a normal dependency). macOS 27+ only —
//  `RetranscriptionEngineKind.availableCases` hides `.coreAINemotron` everywhere below that.
//
//  Unlike `CoreAIParakeetPostSessionEngine` (one whole-file call, chunked around a fixed
//  encoder bucket), this drives the SAME session-based streaming protocol the live
//  `CoreAINemotronTranscriberService` uses — feed a file a few seconds at a time via
//  `session.feed`, then `session.finish()` once — because Nemotron has no bucket to chunk
//  around; the chunking here is purely to report progress. File decode mirrors
//  `NemotronPostSessionEngine`'s AVAudioFile/AVAudioConverter pattern.
//
//  No diarization and no measured per-word timing, matching every other on-device engine —
//  see docs/2026-08-12-macos-coreai-nemotron-streaming.md.
//

import AVFoundation
import Foundation

final class CoreAINemotronPostSessionEngine: PostSessionTranscriptionEngine {

    let capabilities = PostSessionEngineCapabilities(
        engineId: "coreai_nemotron_async",
        displayName: "Offline (Nemotron 3.5, Core AI)",
        supportsDiarization: false,
        isOnDevice: true
    )

    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken] {
        await progress(PostSessionProgress(stage: .preparing))
        let plugin: any CoreAINemotronTranscriptionPlugin
        do {
            plugin = try CoreAIPluginLoader.makeNemotronPlugin()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        try Task.checkCancellation()
        let session = try await Self.makeSession(plugin: plugin)

        try Task.checkCancellation()
        await progress(PostSessionProgress(stage: .transcribing, fraction: 0))

        let durationSeconds = try await feed(audioURL: audioURL, into: session, progress: progress)

        try Task.checkCancellation()
        let text = try await Self.finish(session: session)

        let tokens = Self.tokens(text: text, durationSeconds: durationSeconds)
        guard !tokens.isEmpty else { throw PostSessionEngineError.emptyResult }
        return tokens
    }

    // MARK: - Session bridging

    /// English-only for v1 (see the design doc) — the model's 40-locale support is out of
    /// scope while the rest of the app hardcodes English throughout.
    private static let language = "en-US"

    private static func makeSession(
        plugin: any CoreAINemotronTranscriptionPlugin
    ) async throws -> any CoreAINemotronSession {
        try await withCheckedThrowingContinuation { continuation in
            plugin.makeSession(language: language) { session, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let session {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: PostSessionEngineError.provider("No session returned."))
                }
            }
        }
    }

    private static func finish(session: any CoreAINemotronSession) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            session.finish { text, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: text ?? "")
                }
            }
        }
    }

    // MARK: - File decode → feed

    /// Reads `audioURL` a few seconds at a time, converts each chunk to 16 kHz mono Float32,
    /// and feeds it to `session` — serially, awaiting each completion before reading the next
    /// chunk (the session isn't concurrency-safe). Returns the file's duration in seconds.
    private func feed(
        audioURL: URL,
        into session: any CoreAINemotronSession,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> Double {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }
        let sourceFormat = file.processingFormat
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw PostSessionEngineError.provider("Couldn't set up audio conversion.")
        }

        let totalFrames = file.length
        let durationSeconds = totalFrames > 0 ? Double(totalFrames) / sourceFormat.sampleRate : 0
        let readFrameCapacity = AVAudioFrameCount(sourceFormat.sampleRate * 2)
        var framesRead: AVAudioFramePosition = 0

        while true {
            try Task.checkCancellation()
            guard
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat, frameCapacity: readFrameCapacity)
            else { break }
            try file.read(into: inputBuffer)
            guard inputBuffer.frameLength > 0 else { break }
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: outputCapacity)
            else { break }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            guard conversionError == nil, status != .error else {
                throw PostSessionEngineError.provider(
                    conversionError?.localizedDescription ?? "Audio conversion failed.")
            }

            if outputBuffer.frameLength > 0, let data = Self.data(from: outputBuffer) {
                _ = try await Self.feed(session: session, samples: data)
            }

            if totalFrames > 0 {
                let fraction = min(1, Double(framesRead) / Double(totalFrames))
                await progress(PostSessionProgress(stage: .transcribing, fraction: fraction))
            }
        }

        return durationSeconds
    }

    private static func feed(session: any CoreAINemotronSession, samples: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            session.feed(samples: samples) { text, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: text ?? "")
                }
            }
        }
    }

    /// Raw little-endian Float32 bytes from a mono PCM buffer — the wire format
    /// `CoreAINemotronSession.feed` expects (mirrors `sendAudioChunk(_ data: Data)`).
    private static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.floatChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
    }

    // MARK: - Token mapping

    /// Splits the session's final transcript string into one token per word, timestamps evenly
    /// distributed across the file's duration — the plugin reports no per-word timing (mirrors
    /// `NemotronPostSessionEngine.tokens`).
    private static func tokens(text: String, durationSeconds: Double) -> [PostSessionToken] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let words = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        let totalMs = Int(durationSeconds * 1000)
        return words.enumerated().map { index, word in
            PostSessionToken(
                text: " " + word, speaker: -1,
                startMs: totalMs * index / words.count,
                endMs: totalMs * (index + 1) / words.count
            )
        }
    }
}
