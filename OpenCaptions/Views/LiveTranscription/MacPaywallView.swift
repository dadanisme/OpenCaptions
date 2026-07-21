//
//  MacPaywallView.swift
//  OgmoMac
//
//  Native minute-pack purchase sheet. Reads the `credits` offering packages from
//  `MacSubscriptionManager` and buys via RevenueCat. Hand-rolled (not RevenueCatUI)
//  to match the app's aesthetic and mirror how the iOS target already hand-rolls
//  its paywall. Presented from the pre-record gate, the in-session banners, and the
//  Usage settings pane.
//

import RevenueCat
import StoreKit
import SwiftUI

struct MacPaywallView: View {
    @Environment(MacSubscriptionManager.self) private var billing
    @Environment(\.dismiss) private var dismiss

    /// Called after a purchase completes — e.g. to resume an out-of-minutes session.
    var onPurchased: (() -> Void)?

    /// Product id currently being purchased, for the per-row spinner.
    @State private var purchasingID: String?

    /// Cheapest pack first, so the list reads Starter → Plus → Pro.
    private var sortedPackages: [Package] {
        billing.packages.sorted {
            (billing.minutes(for: $0) ?? 0) < (billing.minutes(for: $1) ?? 0)
        }
    }

    /// Whether any purchasable rows are visible (RevenueCat packages, or the DEBUG
    /// StoreKit fallback). Used to hide the error text when products are showing, so
    /// a transient RevenueCat message doesn't clutter the paywall / a screenshot.
    private var hasProducts: Bool {
        if !billing.packages.isEmpty { return true }
        #if DEBUG
        if !billing.storeKitProducts.isEmpty { return true }
        #endif
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 420)
        .task { if billing.packages.isEmpty { await billing.loadOfferings() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add minutes")
                    .appScaledFont(.title2).fontWeight(.semibold)
                Text("\(billing.remainingMinutes) minutes remaining")
                    .appScaledFont(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .appScaledFont(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            if !billing.packages.isEmpty {
                ForEach(sortedPackages, id: \.identifier) { packageRow($0) }
            } else {
                #if DEBUG
                if billing.storeKitProducts.isEmpty {
                    loadingView
                } else {
                    // DEBUG StoreKit-direct fallback (see MacSubscriptionManager) —
                    // renders the local .storekit products for the IAP screenshot when
                    // RevenueCat has no packages.
                    ForEach(billing.storeKitProducts, id: \.id) { storeKitRow($0) }
                }
                #else
                loadingView
                #endif
            }
            if !hasProducts, let error = billing.errorMessage {
                Text(error)
                    .appScaledFont(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Minutes are shared across your Ogmo apps and never expire. Offline Mode transcribes free on this Mac.")
                .appScaledFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding()
    }

    private var loadingView: some View {
        ProgressView("Loading plans…")
            .appScaledFont(.body)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    private func packageRow(_ package: Package) -> some View {
        let minutes = billing.minutes(for: package)
        let isBuying = purchasingID == package.storeProduct.productIdentifier
        return Button {
            buy(package)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.storeProduct.localizedTitle)
                        .appScaledFont(.headline)
                    if let minutes {
                        Text("\(minutes) minutes")
                            .appScaledFont(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isBuying {
                    ProgressView().controlSize(.small)
                } else {
                    Text(package.storeProduct.localizedPriceString)
                        .appScaledFont(.headline).monospacedDigit()
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .disabled(billing.isPurchasing)
    }

    // MARK: - Purchase

    private func buy(_ package: Package) {
        purchasingID = package.storeProduct.productIdentifier
        Task {
            let ok = await billing.purchase(package)
            purchasingID = nil
            if ok {
                onPurchased?()
                dismiss()
            }
        }
    }

    #if DEBUG
    // MARK: - DEBUG StoreKit fallback

    private func storeKitRow(_ product: StoreKit.Product) -> some View {
        let minutes = MacSubscriptionManager.fallbackProductMinutes[product.id]
        let isBuying = purchasingID == product.id
        return Button {
            buyStoreKit(product)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).appScaledFont(.headline)
                    if let minutes {
                        Text("\(minutes) minutes")
                            .appScaledFont(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isBuying {
                    ProgressView().controlSize(.small)
                } else {
                    Text(product.displayPrice)
                        .appScaledFont(.headline).monospacedDigit()
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .disabled(purchasingID != nil)
    }

    /// Fallback purchase via StoreKit directly (does NOT credit the RevenueCat `Min`
    /// balance — DEBUG/screenshot use only).
    private func buyStoreKit(_ product: StoreKit.Product) {
        purchasingID = product.id
        Task {
            _ = try? await product.purchase()
            purchasingID = nil
        }
    }
    #endif
}
