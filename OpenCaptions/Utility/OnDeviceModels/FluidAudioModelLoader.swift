//
//  FluidAudioModelLoader.swift
//  OpenCaptions
//
//  Stateless helpers for locating, downloading, checking, loading, and cleaning the on-device
//  FluidAudio CoreML models used by the macOS Parakeet (TDT v2) and Nemotron (560 ms) engines.
//
//  The two engines use different FluidAudio download mechanisms:
//   • Parakeet TDT v2 — `AsrModels` (download/load/modelsExist rooted at
//     `AsrModels.defaultCacheDirectory(for: .v2)`), because it drives `SlidingWindowAsrManager`.
//   • Nemotron 560 ms — `DownloadUtils.downloadRepo(_:to:progressHandler:)` + the manager's
//     `loadModels(modelDir:)`, rooted at `modelsRoot` (mirrors FluidAudio's own convention).
//

import FluidAudio
import Foundation

enum FluidAudioModelLoader {

    // MARK: - Nemotron (Repo + DownloadUtils)

    /// The fixed Nemotron 560 ms streaming repo (macOS product choice, issue #175).
    static let nemotronRepo: Repo = .nemotronStreaming560
    /// The fixed Nemotron chunk size the manager is built with.
    static let nemotronChunkSize: NemotronChunkSize = .ms560

    /// Root directory FluidAudio repos are downloaded into and loaded from. Mirrors FluidAudio's
    /// own `applicationSupport/FluidAudio/Models` convention; `Repo.folderName` is appended.
    static var modelsRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The on-disk directory for the Nemotron model files (`modelsRoot/<repo.folderName>`).
    static func nemotronModelDir() -> URL? {
        modelsRoot?.appendingPathComponent(nemotronRepo.folderName, isDirectory: true)
    }

    /// Whether the Nemotron model directory exists on disk and is non-empty.
    static func isNemotronDownloaded() -> Bool {
        guard let dir = nemotronModelDir() else { return false }
        return directoryHasContents(dir)
    }

    /// Downloads the Nemotron repo into `modelsRoot`, reporting fractional progress in [0, 1].
    /// `DownloadUtils.downloadRepo` appends `repo.folderName` to the root, matching `nemotronModelDir`.
    static func downloadNemotron(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let root = modelsRoot else {
            throw TranscriptionServiceError.connectionFailed(underlying: nil)
        }
        try await DownloadUtils.downloadRepo(nemotronRepo, to: root) { snapshot in
            progress(snapshot.fractionCompleted)
        }
    }

    /// Removes the Nemotron cache directory (recover from an interrupted download / reclaim space).
    static func cleanNemotron() {
        guard let dir = nemotronModelDir() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Parakeet TDT v2 (AsrModels)

    /// FluidAudio's default cache directory for the TDT v2 models. Used consistently for
    /// download, presence-check, and load so the three never drift apart.
    static var parakeetCacheDir: URL {
        AsrModels.defaultCacheDirectory(for: .v2)
    }

    /// Whether the TDT v2 model files are present in the cache.
    static func isParakeetDownloaded() -> Bool {
        AsrModels.modelsExist(at: parakeetCacheDir, version: .v2)
    }

    /// Downloads the TDT v2 models into the default cache, reporting fractional progress in [0, 1].
    static func downloadParakeet(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await AsrModels.download(to: parakeetCacheDir, version: .v2) { snapshot in
            progress(snapshot.fractionCompleted)
        }
    }

    /// Loads the downloaded TDT v2 models into memory for `SlidingWindowAsrManager`.
    static func loadParakeetModels() async throws -> AsrModels {
        try await AsrModels.load(from: parakeetCacheDir, version: .v2)
    }

    /// Removes the TDT v2 cache directory (reclaim space).
    static func cleanParakeet() {
        try? FileManager.default.removeItem(at: parakeetCacheDir)
    }

    // MARK: - Shared

    private static func directoryHasContents(_ dir: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }
}
