//
//  MacOfflineDownloadControl.swift
//  OpenCaptions
//
//  The trailing accessory shown on the Offline Mode row while the on-device files aren't
//  ready yet: a prominent Download button, or a compact progress read-out
//  while downloading. Once both models are present the Settings view swaps this out for
//  the real on/off Toggle, so this control never needs a "downloaded" state. Offline needs
//  two models on disk, but that's an implementation detail — this downloads them as one
//  unit and never names a model. Deleting models is left to the upcoming model manager.
//  Issue #274.
//

import SwiftUI

struct MacOfflineDownloadControl: View {

    /// The models backing offline transcription, downloaded together as one unit.
    private var managers: [FluidAudioModelManager] {
        [.nemotron, .parakeet]
    }

    /// Any model actively downloading.
    private var isDownloading: Bool {
        managers.contains { if case .downloading = $0.status { return true } else { return false } }
    }

    /// A download has failed — offer a Retry rather than a first-run Download.
    private var didFail: Bool {
        managers.contains { if case .failed = $0.status { return true } else { return false } }
    }

    /// Combined progress: a ready model counts as done, a downloading one as its
    /// fraction, anything else as not-started. Averaged across both models.
    private var aggregateProgress: Double {
        let total = managers.reduce(0.0) { sum, m in
            switch m.status {
            case .ready: return sum + 1
            case .downloading(let f): return sum + f
            default: return sum
            }
        }
        return managers.isEmpty ? 0 : total / Double(managers.count)
    }

    var body: some View {
        Group {
            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: aggregateProgress)
                        .frame(width: 90)
                    Text("\(Int(aggregateProgress * 100))%")
                        .appScaledFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    downloadMissing()
                } label: {
                    Label(didFail ? "Retry" : "Download", systemImage: "arrow.down.circle")
                        .appScaledFont(.body)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { managers.forEach { $0.refreshStatus() } }
    }

    /// Downloads only the models not already present, concurrently.
    private func downloadMissing() {
        for manager in managers where manager.status != .ready {
            Task { await manager.download() }
        }
    }
}
