//
//  MacLiveTranscriptionView+Billing.swift
//  OpenCaptions
//
//  The in-session minute-billing UI: the low-balance / out-of-minutes banner and
//  the top-up flow. Split out of MacLiveTranscriptionView to keep it under the
//  per-file line limit (same pattern as +AudioSource / +Sharing). Only metered
//  (cloud Soniox) sessions ever surface these — the view model leaves
//  `billingBanner == .none` for free Offline Mode sessions.
//

import SwiftUI

extension MacLiveTranscriptionView {

    /// Low-balance / out-of-minutes banner. Empty (reserves no space) when there's
    /// nothing to show.
    @ViewBuilder
    var billingBannerView: some View {
        switch viewModel.billingBanner {
        case .none:
            EmptyView()
        case .low(let mins):
            billingBar(
                icon: "clock.badge.exclamationmark",
                text: "Less than \(mins) min of transcription left.",
                tint: .orange
            )
        case .out:
            billingBar(
                icon: "exclamationmark.circle.fill",
                text: "You're out of minutes — recording paused.",
                tint: .red
            )
        }
    }

    private func billingBar(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).appScaledFont(.callout)
            Spacer()
            Button("Add minutes") { showPaywall = true }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// Resume after an in-session top-up: recompute the cap against the fresh
    /// balance, clear the banner, and resume if we were paused at the out point.
    func handleTopUp() {
        viewModel.recomputeBudgetAfterTopUp()
        Task { await viewModel.resume() }
    }
}
