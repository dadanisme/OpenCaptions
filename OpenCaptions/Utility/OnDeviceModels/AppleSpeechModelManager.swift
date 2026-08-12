//
//  AppleSpeechModelManager.swift
//  OpenCaptions
//
//  Observable owner of the on-device Apple `Speech` framework asset's lifecycle for the
//  Settings UI, mirroring `FluidAudioModelManager`'s shape but backed by Apple's own
//  `AssetInventory`/`AssetInstallationRequest` asset-management API instead of FluidAudio.
//  `AssetInventory` has no synchronous status check (unlike FluidAudio's plain file-existence
//  one), so `refreshStatus()` fires a background `Task` and republishes `status` once it
//  resolves; callers read the cached, `@MainActor`-isolated property synchronously either way.
//

import Foundation
import Speech

@available(macOS 26.0, *)
@Observable
@MainActor
final class AppleSpeechModelManager: OnDeviceEngineModelManaging {

    static let shared = AppleSpeechModelManager()

    let modelTitle = "Apple Speech model"

    private(set) var status: OnDeviceModelStatus = .unknown

    /// The one locale this engine transcribes — matches `SpeechAnalyzerTranscriberService`'s
    /// hardcoded `en-US`. No locale picker; see docs/2026-08-12-macos-speechanalyzer-engine.md.
    private static let locale = Locale(identifier: "en-US")

    private var progressObservation: NSKeyValueObservation?

    private init() {
        refreshStatus()
    }

    // MARK: - Status

    func refreshStatus() {
        if case .downloading = status { return }
        Task { await self.refreshStatusFromAssetInventory() }
    }

    private func refreshStatusFromAssetInventory() async {
        let transcriber = SpeechTranscriber(locale: Self.locale, preset: .transcription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if case .downloading = status { return }
        status = Self.map(assetStatus)
    }

    private static func map(_ status: AssetInventory.Status) -> OnDeviceModelStatus {
        switch status {
        case .installed: return .ready
        case .supported: return .notDownloaded
        case .downloading: return .downloading(0)
        case .unsupported:
            return .failed("This Mac doesn't support Apple Speech on-device transcription.")
        @unknown default:
            return .failed("Unknown Apple Speech asset status.")
        }
    }

    // MARK: - Download

    /// Downloads the locale asset, reporting fractional progress via the request's plain
    /// `Progress` KVO (`AssetInventory` has no async progress sequence, unlike FluidAudio's
    /// snapshot stream).
    func download() async {
        if case .downloading = status { return }
        status = .downloading(0)

        let transcriber = SpeechTranscriber(locale: Self.locale, preset: .transcription)
        do {
            guard
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber])
            else {
                // Nothing to install — already installed, or unsupported.
                await refreshStatusFromAssetInventory()
                return
            }
            observeProgress(of: request)
            try await request.downloadAndInstall()
            progressObservation?.invalidate()
            progressObservation = nil
            await refreshStatusFromAssetInventory()
        } catch {
            progressObservation?.invalidate()
            progressObservation = nil
            status = .failed(error.localizedDescription)
        }
    }

    private func observeProgress(of request: AssetInstallationRequest) {
        progressObservation = request.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] progress, _ in
            Task { @MainActor in
                guard let self, case .downloading = self.status else { return }
                self.status = .downloading(progress.fractionCompleted)
            }
        }
    }
}
