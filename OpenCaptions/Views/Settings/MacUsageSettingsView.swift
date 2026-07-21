//
//  MacUsageSettingsView.swift
//  OgmoMac
//
//  The Settings → Usage pane: shows the remaining transcription-minute balance
//  and a button to buy more (opens the native paywall). Minutes meter cloud
//  (Soniox) recording only; Offline Mode is free, which the footnote explains.
//

import SwiftUI

struct MacUsageSettingsView: View {
    @Environment(MacSubscriptionManager.self) private var billing
    @State private var showPaywall = false

    var body: some View {
        Form {
            Section("Transcription minutes") {
                LabeledContent("Remaining") {
                    if billing.loadState == .loaded {
                        Text("\(billing.remainingMinutes) minutes")
                            .appScaledFont(.body).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Button {
                    showPaywall = true
                } label: {
                    Label("Add minutes", systemImage: "plus.circle")
                }
                Button {
                    Task { await billing.refreshStatus() }
                } label: {
                    Label("Refresh balance", systemImage: "arrow.clockwise")
                }
            }
            Section {
                Text("Minutes are consumed by cloud transcription (with speaker labels) and are shared across your Ogmo apps. Offline Mode transcribes entirely on this Mac and is free — it never uses minutes.")
                    .appScaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if billing.packages.isEmpty { await billing.loadOfferings() } }
        .sheet(isPresented: $showPaywall) { MacPaywallView() }
    }
}

#Preview {
    MacUsageSettingsView()
        .environment(MacSubscriptionManager.shared)
}
