//
//  MacOfflineDownloadControl.swift
//  OpenCaptions
//
//  The trailing accessory shown on the Transcription Engine row while the
//  SELECTED on-device model isn't downloaded yet: a prominent Download button, or
//  a compact progress read-out while downloading. Once the model is `.ready` the
//  Settings view drops this control entirely — it never needs a "downloaded"
//  state itself. Per-model: the three-way selector only ever needs the ONE model
//  the current selection points at, unlike the old binary Offline Mode row, which
//  downloaded both on-device models together as a single unit.
//

import SwiftUI

struct MacOfflineDownloadControl: View {
    let manager: FluidAudioModelManager

    private var isDownloading: Bool {
        if case .downloading = manager.status { return true }
        return false
    }

    private var didFail: Bool {
        if case .failed = manager.status { return true }
        return false
    }

    private var progressFraction: Double {
        if case .downloading(let fraction) = manager.status { return fraction }
        return manager.status == .ready ? 1 : 0
    }

    var body: some View {
        Group {
            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: progressFraction)
                        .frame(width: 90)
                    Text("\(Int(progressFraction * 100))%")
                        .appScaledFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await manager.download() }
                } label: {
                    Label(didFail ? "Retry" : "Download", systemImage: "arrow.down.circle")
                        .appScaledFont(.body)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { manager.refreshStatus() }
    }
}
