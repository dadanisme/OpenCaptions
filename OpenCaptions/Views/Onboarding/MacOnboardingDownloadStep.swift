//
//  MacOnboardingDownloadStep.swift
//  OpenCaptions
//
//  Step 3 (offline path): download the on-device speech model. Offline
//  transcription hard-fails at record time without the model on disk
//  (`MacTranscriptionViewModel.start`), so the coordinator blocks Continue until
//  both FluidAudio models report `.ready`. Reuses the same managers as
//  Settings → Recording, so a model already downloaded there shows ready instantly.
//

import SwiftUI

struct MacOnboardingDownloadStep: View {
    /// Offline needs both models present (Nemotron for streaming, Parakeet reserved
    /// for a future offline re-transcribe) — downloaded together as one unit.
    private var managers: [FluidAudioModelManager] { [.nemotron, .parakeet] }

    private var isReady: Bool { managers.allSatisfy { $0.status == .ready } }

    private var isDownloading: Bool {
        managers.contains { if case .downloading = $0.status { return true } else { return false } }
    }

    private var didFail: Bool {
        managers.contains { if case .failed = $0.status { return true } else { return false } }
    }

    /// A ready model counts as done, a downloading one as its fraction; averaged.
    private var aggregateProgress: Double {
        let total = managers.reduce(0.0) { sum, manager in
            switch manager.status {
            case .ready: return sum + 1
            case .downloading(let fraction): return sum + fraction
            default: return sum
            }
        }
        return managers.isEmpty ? 0 : total / Double(managers.count)
    }

    var body: some View {
        VStack(spacing: 22) {
            MacOnboardingHeader(
                systemImage: isReady ? "checkmark.seal" : "arrow.down.circle",
                title: "Download the offline model",
                subtitle: "Open Captions transcribes on-device using speech models. It's a one-time download of about 1.2 GB — after that, everything works without a network.",
                isComplete: isReady
            )

            card
                .frame(maxWidth: 360)

            Label(
                "You can switch to cloud transcription anytime from Settings → General → Transcription Engine.",
                systemImage: "info.circle"
            )
            .appScaledFont(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360)
        }
        .onAppear { managers.forEach { $0.refreshStatus() } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .appScaledFont(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("On-device speech model")
                        .appScaledFont(.subheadline)
                        .fontWeight(.semibold)
                    Text("Nemotron · runs locally · private")
                        .appScaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if isReady {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .appScaledFont(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            } else if isDownloading {
                HStack(spacing: 12) {
                    ProgressView(value: aggregateProgress)
                    Text("\(Int(aggregateProgress * 100))%")
                        .appScaledFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(action: downloadMissing) {
                    Label(didFail ? "Retry Download" : "Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func downloadMissing() {
        for manager in managers where manager.status != .ready {
            Task { await manager.download() }
        }
    }
}
