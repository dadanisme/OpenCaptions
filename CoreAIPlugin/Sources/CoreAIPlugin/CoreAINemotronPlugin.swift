//
//  CoreAINemotronPlugin.swift
//  CoreAIPlugin
//
//  Real streaming transcription via john-rocky/coreai-kit's `KitNemotronModel` — NVIDIA's
//  Nemotron 3.5 ASR Streaming 0.6B, a genuine cache-aware streaming architecture (320ms chunks,
//  explicit KV-sliding-window/causal-conv graph I/O), unlike Parakeet's fixed ~28.84s encoder
//  bucket (CoreAIParakeetPlugin.swift). No manual chunking workaround is needed here: `feed`
//  accepts packets of any size and the model's own mel frontend does the chunking internally.
//  See docs/2026-08-12-macos-coreai-nemotron-streaming.md.
//
//  The compiled model is cached for the plugin's lifetime (`ModelCache`) rather than reloaded
//  per call like `CoreAIParakeetPlugin` — Nemotron's first load recompiles six on-device graphs
//  (~50s per the model card), and it's the SAME model backing both live sessions and batch
//  re-transcription, so paying that cost once via the Settings Download control (which calls
//  `downloadModel`) matters far more here than it did for Parakeet's batch-only stub.
//
//  Diarization: coreai-kit also ships a Sortformer diarizer (`KitDiarizer`), but issue #55 scopes
//  this integration to transcription only, consistent with every other on-device engine having no
//  diarization — worth revisiting as its own follow-up, not bundled in here.
//

import CoreAIKit
import Foundation

private let nemotronCatalogID = "nemotron-3.5-asr-streaming-0.6b"

final class CoreAINemotronPlugin: NSObject, CoreAINemotronTranscriptionPlugin {

    /// Actor-isolated so concurrent calls (e.g. a Settings download tap racing a live session
    /// start) can't trigger two independent loads; the second caller just awaits the first's result.
    private actor ModelCache {
        private var model: KitNemotronModel?
        private var loadTask: Task<KitNemotronModel, Error>?

        func get(downloadProgress: (@Sendable (DownloadProgress) -> Void)?) async throws -> KitNemotronModel {
            if let model { return model }
            if let loadTask { return try await loadTask.value }
            let task = Task<KitNemotronModel, Error> {
                try await KitNemotronModel(catalog: nemotronCatalogID, downloadProgress: downloadProgress)
            }
            loadTask = task
            do {
                let loaded = try await task.value
                model = loaded
                loadTask = nil
                return loaded
            } catch {
                loadTask = nil
                throw error
            }
        }
    }

    private let cache = ModelCache()

    func isModelDownloaded() -> Bool {
        ModelStore.default.localURL(for: .nemotronASRStreaming) != nil
    }

    func downloadModel(
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        Task {
            do {
                _ = try await cache.get(downloadProgress: { progress($0.fraction) })
                completion(true, nil)
            } catch {
                completion(false, error)
            }
        }
    }

    func makeSession(
        language: String,
        completion: @escaping @Sendable (CoreAINemotronSession?, Error?) -> Void
    ) {
        Task {
            do {
                let model = try await cache.get(downloadProgress: nil)
                let session = try model.makeSession(language: language)
                completion(CoreAINemotronSessionImpl(session: session), nil)
            } catch {
                completion(nil, error)
            }
        }
    }
}

/// Wraps one `NemotronStreamSession` behind the dlopen boundary. Samples cross as raw `Data`
/// (mirrors the app-side `RealtimeTranscriptionEngine.sendAudioChunk(_ data: Data)` convention)
/// since a bare `[Float]` isn't `@objc`-representable; `floats(from:)` reinterprets the bytes
/// back to `[Float]` on this side.
final class CoreAINemotronSessionImpl: NSObject, CoreAINemotronSession {
    private let session: NemotronStreamSession

    init(session: NemotronStreamSession) {
        self.session = session
    }

    func feed(samples: Data, completion: @escaping @Sendable (String?, Error?) -> Void) {
        let floats = Self.floats(from: samples)
        Task {
            do {
                let text = try await session.feed(samples: floats)
                completion(text, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    func finish(completion: @escaping @Sendable (String?, Error?) -> Void) {
        Task {
            do {
                let result = try await session.finish()
                completion(result.text, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    private static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
