//
//  SpeechAnalyzerPostSessionEngine.swift
//  OpenCaptions
//
//  On-device (offline) post-session re-transcription via Apple's `Speech` framework
//  `SpeechAnalyzer` reading a whole audio file end-to-end (WWDC25, macOS 26+). Unlike the
//  FluidAudio post-session engines, this needs no manual `AVAudioFile`/`AVAudioConverter`
//  decode loop — `SpeechAnalyzer.start(inputAudioFile:finishAfterFile:)` is a purpose-built
//  batch path. Real per-word timestamps come from `attributeOptions: [.audioTimeRange]`, unlike
//  Nemotron's evenly-estimated ones. No diarization (every token is speaker -1).
//

import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, *)
final class SpeechAnalyzerPostSessionEngine: PostSessionTranscriptionEngine {

    let capabilities = PostSessionEngineCapabilities(
        engineId: "appleSpeech_async",
        displayName: "Offline (Apple Speech)",
        supportsDiarization: false,
        isOnDevice: true
    )

    private static let locale = Locale(identifier: "en-US")

    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken] {
        guard await AppleSpeechModelManager.shared.status == .ready else {
            throw PostSessionEngineError.modelNotDownloaded
        }
        await progress(PostSessionProgress(stage: .preparing))

        let locale =
            await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) ?? Self.locale
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        try Task.checkCancellation()
        // No progress fraction from this API (unlike FluidAudio's snapshot stream) — the whole
        // file decodes in one pass with no incremental signal to forward.
        await progress(PostSessionProgress(stage: .transcribing))

        // Runs concurrently with the results loop below; `SpeechAnalyzer.start(inputAudioFile:)`
        // is the purpose-built whole-file batch path (see file header).
        async let startResult: Void = analyzer.start(
            inputAudioFile: audioFile, finishAfterFile: true)

        var tokens: [PostSessionToken] = []
        do {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                tokens.append(contentsOf: Self.tokens(from: result))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        do {
            try await startResult
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        guard !tokens.isEmpty else { throw PostSessionEngineError.emptyResult }
        return tokens
    }

    // MARK: - Token mapping

    /// Maps each attributed run carrying a real `.audioTimeRange` into a `PostSessionToken`,
    /// with a leading space so `PostSessionSegmentBuilder` joins them like the Soniox/Parakeet
    /// convention. A run without the attribute (shouldn't happen given `attributeOptions:
    /// [.audioTimeRange]`, but the attribute is still optional per run) is skipped.
    private static func tokens(from result: SpeechTranscriber.Result) -> [PostSessionToken] {
        var tokens: [PostSessionToken] = []
        for run in result.text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let text = String(result.text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            tokens.append(
                PostSessionToken(
                    text: " " + text, speaker: -1,
                    startMs: Int(timeRange.start.seconds * 1000),
                    endMs: Int((timeRange.start + timeRange.duration).seconds * 1000)
                ))
        }
        return tokens
    }
}
