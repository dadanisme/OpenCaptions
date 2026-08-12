//
//  CoreAIParakeetPostSessionEngine.swift
//  OpenCaptions
//
//  On-device post-session re-transcription via Apple's Core AI Parakeet export,
//  loaded through CoreAIPluginLoader (see its header for why this needs a
//  dlopen'd sibling package rather than a normal dependency). macOS 27+ only —
//  `RetranscriptionEngineKind.availableCases` hides `.coreAIParakeet` everywhere
//  below that, so this engine is never constructed on an older OS.
//
//  Real transcription via coreai-kit's `KitParakeetModel` runs in the plugin
//  itself (see CoreAIParakeetPlugin.swift). Token splitting mirrors
//  `NemotronPostSessionEngine`'s approach — the plugin reports only a final
//  transcript string, no per-word timing, so timestamps are evenly
//  distributed across the file's duration.
//

import AVFoundation
import Foundation

final class CoreAIParakeetPostSessionEngine: PostSessionTranscriptionEngine {

    let capabilities = PostSessionEngineCapabilities(
        engineId: "coreai_parakeet_async",
        displayName: "Offline (Parakeet, Core AI)",
        supportsDiarization: false,
        isOnDevice: true
    )

    func transcribe(
        audioURL: URL,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws -> [PostSessionToken] {
        await progress(PostSessionProgress(stage: .preparing))
        let plugin: any CoreAITranscriptionPlugin
        do {
            plugin = try CoreAIPluginLoader.makePlugin()
        } catch {
            throw PostSessionEngineError.provider(error.localizedDescription)
        }

        try Task.checkCancellation()
        await progress(PostSessionProgress(stage: .transcribing))

        let durationSeconds = (try? await AVURLAsset(url: audioURL).load(.duration).seconds) ?? 0

        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            plugin.transcribe(audioFileURL: audioURL) { text, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: text ?? "")
                }
            }
        }

        try Task.checkCancellation()
        let tokens = Self.tokens(text: text, durationSeconds: durationSeconds)
        guard !tokens.isEmpty else { throw PostSessionEngineError.emptyResult }
        return tokens
    }

    /// Splits the plugin's final transcript string into one token per word,
    /// timestamps evenly distributed across the file's duration — the plugin
    /// reports no per-word timing (mirrors `NemotronPostSessionEngine.tokens`).
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
