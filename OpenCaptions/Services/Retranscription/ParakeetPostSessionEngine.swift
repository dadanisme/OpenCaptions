//
//  ParakeetPostSessionEngine.swift
//  OpenCaptions
//
//  On-device (offline) post-session re-transcription via FluidAudio's batch
//  `AsrManager` over the Parakeet TDT v2 model (`parakeet-tdt-0.6b-v2`, English-only,
//  highest-accuracy). Unlike the live `ParakeetTranscriberService` (which streams a
//  sliding window), this runs a single full-file decode — the whole recording with
//  full context — which is exactly what makes a re-transcription more accurate than
//  the original live pass. Audio never leaves the device.
//  No diarization (every token is speaker -1).
//

import AVFoundation
import FluidAudio
import Foundation

final class ParakeetPostSessionEngine: PostSessionTranscriptionEngine {

    let capabilities = PostSessionEngineCapabilities(
        engineId: "parakeet_async",
        displayName: "Offline (Parakeet TDT v2)",
        supportsDiarization: false,
        isOnDevice: true
    )

    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken] {
        guard FluidAudioModelLoader.isParakeetDownloaded() else {
            throw PostSessionEngineError.modelNotDownloaded
        }
        await progress(PostSessionProgress(stage: .preparing))

        // Load the already-downloaded TDT v2 models into a fresh batch manager.
        let models = try await FluidAudioModelLoader.loadParakeetModels()
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        // `cleanup()` releases the CoreML models regardless of success/throw/cancel.
        defer { Task { await asr.cleanup() } }

        try Task.checkCancellation()
        await progress(PostSessionProgress(stage: .transcribing, fraction: 0))

        // FluidAudio only emits progress for audio longer than ~15 s; obtain the
        // stream BEFORE `transcribe` (per its docs) and forward it to the overlay.
        let progressStream = await asr.transcriptionProgressStream
        let progressTask = Task {
            for try await fraction in progressStream {
                await progress(PostSessionProgress(stage: .transcribing, fraction: fraction))
            }
        }
        defer { progressTask.cancel() }

        // Fresh TDT decoder state for this single full-file decode; `transcribe`
        // takes it `inout` (there is no prior streaming state to carry over).
        var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)

        // Full-file batch decode. The URL overload decodes/resamples the `.m4a` to
        // 16 kHz mono internally and auto-chunks long recordings at constant memory.
        let result: ASRResult
        do {
            result = try await asr.transcribe(audioURL, decoderState: &decoderState)
        } catch is CancellationError {
            // FluidAudio's decode checks Task cancellation internally; let a user
            // cancel propagate as-is so the caller dismisses cleanly (no error alert).
            throw CancellationError()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        try Task.checkCancellation()
        let tokens = Self.tokens(from: result)
        guard !tokens.isEmpty else { throw PostSessionEngineError.emptyResult }
        return tokens
    }

    // MARK: - Token mapping

    /// Rebuilds clean word-level tokens (with accurate per-word timings) from the
    /// sub-word `tokenTimings`. FluidAudio uses SentencePiece: a sub-token beginning
    /// with `▁` (U+2581) or a space starts a new word; the marker maps to a space.
    /// Falls back to one whole-transcript token when timings are unavailable.
    private static func tokens(from result: ASRResult) -> [PostSessionToken] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [PostSessionToken(
                text: text, speaker: -1,
                startMs: 0, endMs: Int(result.duration * 1000)
            )]
        }

        var words: [PostSessionToken] = []
        var wordText = ""
        var wordStart: TimeInterval = 0
        var wordEnd: TimeInterval = 0
        var open = false

        func commit() {
            let clean = wordText.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                // Leading space so `PostSessionSegmentBuilder` joins words like the
                // Soniox path (which prepends a space to each word token).
                words.append(PostSessionToken(
                    text: " " + clean, speaker: -1,
                    startMs: Int(wordStart * 1000), endMs: Int(wordEnd * 1000)
                ))
            }
            wordText = ""
            open = false
        }

        for timing in timings {
            let raw = timing.token
            let startsWord = raw.hasPrefix("\u{2581}") || raw.hasPrefix(" ")
            let piece = raw.replacingOccurrences(of: "\u{2581}", with: " ")
            if startsWord || !open {
                commit()
                wordText = piece.trimmingCharacters(in: .whitespaces)
                wordStart = timing.startTime
                wordEnd = timing.endTime
                open = true
            } else {
                wordText += piece
                wordEnd = timing.endTime
            }
        }
        commit()
        return words
    }
}
