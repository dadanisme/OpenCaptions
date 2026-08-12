//
//  NemotronPostSessionEngine.swift
//  OpenCaptions
//
//  On-device (offline) post-session re-transcription via FluidAudio's streaming
//  `StreamingNemotronAsrManager` over the Nemotron 560 ms model. Unlike the live
//  `NemotronTranscriberService` (fed live mic chunks), this drives the same
//  manager over a file read from disk, start to finish, then reads back the
//  whole transcript once `finish()` flushes the tail. FluidAudio exposes no
//  URL-based batch call for Nemotron (unlike Parakeet's `AsrManager.transcribe`),
//  so this is the one post-session engine that does its own file decode/resample
//  — via `AVAudioFile` + `AVAudioConverter` to 16 kHz mono Float32, mirroring the
//  live-capture conversion pattern in `MacAudioService`.
//
//  No diarization and no measured per-word timing: Nemotron reports only the
//  running full transcript, matching its live-capture characteristics
//  (`providesReliableTimestamps == false` on `NemotronTranscriberService`). The
//  transcript is split into one token per word, timestamps evenly distributed
//  across the file's duration (not measured), so `PostSessionSegmentBuilder`'s
//  punctuation/word-count splitting — which only fires BETWEEN tokens — still
//  produces real paragraphs instead of one unsplittable blob.
//

import AVFoundation
import FluidAudio
import Foundation

final class NemotronPostSessionEngine: PostSessionTranscriptionEngine {

    let capabilities = PostSessionEngineCapabilities(
        engineId: "nemotron_async",
        displayName: "Offline (Nemotron 560 ms)",
        supportsDiarization: false,
        isOnDevice: true
    )

    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken] {
        guard FluidAudioModelLoader.isNemotronDownloaded(),
            let dir = FluidAudioModelLoader.nemotronModelDir()
        else {
            throw PostSessionEngineError.modelNotDownloaded
        }
        await progress(PostSessionProgress(stage: .preparing))

        let manager = StreamingNemotronAsrManager(
            requestedChunkSize: NemotronEngineConfig().chunkSize)
        do {
            try await manager.loadModels(from: dir)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }
        // `cleanup()` releases the CoreML models regardless of success/throw/cancel.
        defer { Task { await manager.cleanup() } }

        try Task.checkCancellation()
        await progress(PostSessionProgress(stage: .transcribing, fraction: 0))

        let durationSeconds = try await feed(audioURL: audioURL, into: manager, progress: progress)

        try Task.checkCancellation()
        let text: String
        do {
            text = try await manager.finish()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        let tokens = Self.tokens(text: text, durationSeconds: durationSeconds)
        guard !tokens.isEmpty else { throw PostSessionEngineError.emptyResult }
        return tokens
    }

    // MARK: - File decode → feed

    /// Reads `audioURL` a few seconds at a time, converts each chunk to 16 kHz mono
    /// Float32, and feeds it to `manager`. The manager buffers internally and only
    /// processes complete `chunkSamples`-sized windows as they accumulate, so the
    /// buffers handed to it don't need to be pre-sliced to that exact size. Returns
    /// the file's duration in seconds (from its declared frame count / sample rate).
    private func feed(
        audioURL: URL,
        into manager: StreamingNemotronAsrManager,
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

            if outputBuffer.frameLength > 0 {
                do {
                    _ = try await manager.process(audioBuffer: outputBuffer)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw PostSessionEngineError.provider(error.localizedDescription)
                }
            }

            if totalFrames > 0 {
                let fraction = min(1, Double(framesRead) / Double(totalFrames))
                await progress(PostSessionProgress(stage: .transcribing, fraction: fraction))
            }
        }

        return durationSeconds
    }

    // MARK: - Token mapping

    /// Splits Nemotron's final full-transcript string into one token per word
    /// (leading space, matching the Soniox/Parakeet convention `PostSessionSegmentBuilder`
    /// expects), with timestamps evenly distributed across the file's duration —
    /// Nemotron never reports a per-word measurement, so this is a coarse
    /// estimate, not a real one. Splitting on whitespace alone (rather than
    /// returning the whole string as one token) is what lets the segment
    /// builder's punctuation/word-count checks — which only fire BETWEEN tokens
    /// — actually produce multiple paragraphs.
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
