//
//  FluidAudioModelManager.swift
//  OpenCaptions
//
//  Observable owner of an on-device FluidAudio model's lifecycle for the Settings UI: reports
//  its download status and drives an explicit pre-download (with progress) so recording never
//  blocks on a multi-hundred-MB fetch. The engine services check `isModelDownloaded` at start
//  and throw (surfacing a "download it in Settings" hint) rather than downloading on demand.
//
//  One instance per engine (`.parakeet`, `.nemotron`). Each dispatches to the matching
//  `FluidAudioModelLoader` mechanism (AsrModels for Parakeet TDT v2, ModelHub for Nemotron).
//

import Foundation

@Observable
@MainActor
final class FluidAudioModelManager {

    /// The two on-device engines, each with its own download state.
    static let parakeet = FluidAudioModelManager(engine: .parakeet)
    static let nemotron = FluidAudioModelManager(engine: .nemotron)

    enum Engine: String {
        case parakeet
        case nemotron

        /// User-facing model name for the Settings download card title.
        var modelTitle: String {
            switch self {
            case .parakeet: return "Parakeet TDT v2 model"
            case .nemotron: return "Nemotron 560 ms model"
            }
        }
    }

    enum Status: Equatable {
        case unknown
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    let engine: Engine
    private(set) var status: Status = .unknown

    private init(engine: Engine) {
        self.engine = engine
        refreshStatus()
    }

    // MARK: - Status

    private var isDownloaded: Bool {
        switch engine {
        case .parakeet: return FluidAudioModelLoader.isParakeetDownloaded()
        case .nemotron: return FluidAudioModelLoader.isNemotronDownloaded()
        }
    }

    /// Re-checks disk presence. No-op while a download is in flight.
    func refreshStatus() {
        if case .downloading = status { return }
        status = isDownloaded ? .ready : .notDownloaded
    }

    // MARK: - Download / Delete

    /// Downloads the model, reporting fractional progress. Cleans up a partial download on failure.
    func download() async {
        if case .downloading = status { return }
        status = .downloading(0)
        do {
            try await runDownload { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(fraction)
                }
            }
            status = isDownloaded ? .ready : .failed("Download incomplete")
        } catch {
            clean()
            status = .failed(error.localizedDescription)
        }
    }

    /// Removes the model from disk to reclaim space.
    func delete() {
        clean()
        status = .notDownloaded
    }

    // MARK: - Dispatch

    private func runDownload(progress: @escaping @Sendable (Double) -> Void) async throws {
        switch engine {
        case .parakeet: try await FluidAudioModelLoader.downloadParakeet(progress: progress)
        case .nemotron: try await FluidAudioModelLoader.downloadNemotron(progress: progress)
        }
    }

    private func clean() {
        switch engine {
        case .parakeet: FluidAudioModelLoader.cleanParakeet()
        case .nemotron: FluidAudioModelLoader.cleanNemotron()
        }
    }
}
