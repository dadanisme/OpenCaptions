//
//  MacPreparingModelOverlay.swift
//  OgmoMac
//
//  A lightweight dimming overlay shown over the live transcript while an on-device engine loads
//  its CoreML model in `connectAndStart()` (`MacTranscriptionViewModel.isPreparingEngine`). The
//  cloud Soniox path never shows it. macOS UI is hardcoded English (no LanguageManager).
//

import SwiftUI

struct MacPreparingModelOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing model…")
                    .appScaledFont(.headline)
                Text("Loading the on-device speech model. This can take a few seconds the first time.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    MacPreparingModelOverlay()
        .frame(width: 480, height: 360)
}
