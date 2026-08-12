//
//  OnDeviceModelManaging.swift
//  OpenCaptions
//
//  Shared readiness surface for an on-device engine's model/asset lifecycle, so
//  `MacTranscriptionEngineKind.modelManager` and the Settings UI (`MacOfflineDownloadControl`,
//  `MacSettingsView`) can treat every on-device engine the same regardless of which download
//  mechanism backs it. `FluidAudioModelManager` (Parakeet/Nemotron, file-existence-backed)
//  and `AppleSpeechModelManager` (Apple Speech, `AssetInventory`-backed) both conform.
//

import Foundation

/// Mirrors `FluidAudioModelManager`'s original `Status` shape so both download mechanisms report
/// through the same five cases.
enum OnDeviceModelStatus: Equatable {
    case unknown
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)
}

@MainActor
protocol OnDeviceEngineModelManaging: AnyObject {
    /// User-facing model name for the Settings download card title.
    var modelTitle: String { get }
    var status: OnDeviceModelStatus { get }

    /// Re-checks whether the model/asset is present. No-op while a download is in flight.
    func refreshStatus()
    /// Downloads the model/asset, reporting fractional progress via `status`.
    func download() async
}
