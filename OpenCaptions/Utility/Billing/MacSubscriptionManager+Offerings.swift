//
//  MacSubscriptionManager+Offerings.swift
//  OgmoMac
//
//  Offering load + purchase, split out of `MacSubscriptionManager` to keep it
//  focused. Reads the `credits` offering (fallback: the current offering) and
//  exposes the minutes-per-pack lookup used by the paywall.
//

import Foundation
import RevenueCat
import StoreKit

extension MacSubscriptionManager {

    /// Minutes granted by a package (nil for an unknown package identifier).
    func minutes(for package: Package) -> Int? {
        Self.packageMinutes[package.identifier]
    }

    // MARK: - Load offerings

    func loadOfferings() async {
        guard Purchases.isConfigured else {
            // No RevenueCat key configured — still render products for a DEBUG
            // screenshot straight from StoreKit (the local `.storekit` config).
            #if DEBUG
            await loadStoreKitFallback()
            #endif
            return
        }
        do {
            let offerings = try await Purchases.shared.offerings()
            let offering = offerings[Self.offeringID] ?? offerings.current
            packages = offering?.availablePackages ?? []
            if packages.isEmpty {
                print("⚠️ No packages in offering '\(Self.offeringID)' or current — check RC dashboard.")
                #if DEBUG
                await loadStoreKitFallback()
                #endif
            }
        } catch {
            errorMessage = "Failed to load plans: \(error.localizedDescription)"
            #if DEBUG
            await loadStoreKitFallback()
            #endif
        }
    }

    #if DEBUG
    /// DEBUG-only: loads the macOS minute-pack products directly from StoreKit so the
    /// paywall renders when RevenueCat has no packages (empty offering, RC outage, or
    /// no key). Used to generate the App Store IAP review screenshot from the local
    /// `.storekit` config without depending on the RevenueCat offering. If this also
    /// returns 0 products, the StoreKit config isn't active or the ids don't match.
    func loadStoreKitFallback() async {
        do {
            let ids = Set(Self.fallbackProductMinutes.keys)
            storeKitProducts = try await StoreKit.Product.products(for: ids)
                .sorted { $0.price < $1.price }
            // Fallback rendered — drop the RevenueCat "failed to load" message so it
            // doesn't clutter the paywall (and a screenshot).
            if !storeKitProducts.isEmpty { errorMessage = nil }
            print("[Billing] StoreKit fallback loaded \(storeKitProducts.count) product(s): "
                  + storeKitProducts.map(\.id).joined(separator: ", "))
        } catch {
            print("[Billing] StoreKit fallback failed: \(error)")
        }
    }
    #endif

    // MARK: - Purchase

    /// Returns true only when a purchase actually completed (not cancelled/failed).
    /// RevenueCat grants the `Min` currency on purchase, so the balance is refreshed
    /// afterward.
    @discardableResult
    func purchase(_ package: Package) async -> Bool {
        guard Purchases.isConfigured else { return false }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return false }
            do {
                try await refreshMinuteBalance()
            } catch {
                print("[MinutesSync] Balance refresh after purchase failed: \(error)")
            }
            return true
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }
}
