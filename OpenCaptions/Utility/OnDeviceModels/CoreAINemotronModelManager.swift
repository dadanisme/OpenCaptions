//
//  CoreAINemotronModelManager.swift
//  OpenCaptions
//
//  Observable owner of the Core AI Nemotron streaming model's download lifecycle for the
//  Settings UI — mirrors `FluidAudioModelManager` and `AppleSpeechModelManager` (issue #55's
//  "mirror the per-model Download control pattern" ask) via the shared
//  `OnDeviceEngineModelManaging` protocol, so `MacOfflineDownloadControl` needs no changes
//  beyond widening its parameter type.
//
//  Unlike FluidAudio's plain file-copy download, "downloading" this model also compiles its six
//  on-device graphs (~50s the first time, per the model card) — see `CoreAINemotronPlugin
//  .ModelCache`. Paying that cost here, from an explicit Download tap, means a live session's
//  own `connectAndStart()` only ever hits the cheap ~4s cached path.
//

import Foundation

@Observable
@MainActor
final class CoreAINemotronModelManager: OnDeviceEngineModelManaging {

    static let shared = CoreAINemotronModelManager()

    let modelTitle = "Nemotron 3.5 streaming model (Core AI)"
    private(set) var status: OnDeviceModelStatus = .unknown

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        if case .downloading = status { return }
        status = CoreAIPluginLoader.isNemotronModelDownloaded() ? .ready : .notDownloaded
    }

    func download() async {
        if case .downloading = status { return }
        status = .downloading(0)
        do {
            let plugin = try CoreAIPluginLoader.makeNemotronPlugin()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                plugin.downloadModel(
                    progress: { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, case .downloading = self.status else { return }
                            self.status = .downloading(fraction)
                        }
                    },
                    completion: { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: CoreAIPluginLoader.LoadError.unavailable)
                        }
                    }
                )
            }
            status = CoreAIPluginLoader.isNemotronModelDownloaded() ? .ready : .failed("Download incomplete")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
