//
//  MacSubscriptionManager.swift
//  OpenCaptions
//
//  RevenueCat wrapper + consumable-minute balance for the standalone macOS app.
//  Ported from the iOS `SubscriptionManager` but rebuilt as an `@Observable`
//  singleton (matching `MacAuthManager`) instead of `ObservableObject`.
//
//  Billing model: minutes are bought as consumable IAPs from the `credits`
//  offering; RevenueCat grants the `Min` virtual currency on purchase; access is
//  gated purely on the remaining-minute balance. macOS shares the SAME RevenueCat
//  project as iOS, so the `Min` balance is shared per Firebase uid — a purchase on
//  either platform credits the same balance (only the store products + public SDK
//  key differ per platform). See docs/2026-07-10-macos-consumable-billing.md.
//
//  Only cloud Soniox sessions are metered; Offline Mode (on-device) is free.
//  Minute-deduction API calls are delegated to `MacMinuteDeductionService`.
//

import Foundation
import RevenueCat
import StoreKit

// MARK: - Load State

enum MacSubscriptionLoadState {
    case loading
    case loaded
    case failed
}

// MARK: - Subscription Manager

@Observable
@MainActor
final class MacSubscriptionManager {

    static let shared = MacSubscriptionManager()
    private init() {}

    // MARK: - Server-coupled identifiers (shared RevenueCat project with iOS)

    /// Offering that holds the minute packs; falls back to `offerings.current`.
    static let offeringID = "credits"
    /// Virtual-currency code the minute balance is read from.
    static let currencyCode = "Min"
    /// Minutes granted per package, keyed by RevenueCat **package** identifier
    /// (platform-agnostic — the store's minute products attach to these packages).
    static let packageMinutes: [String: Int] = ["starter": 180, "plus": 600, "pro": 1500]

    // MARK: - Observed state

    var loadState: MacSubscriptionLoadState = .loading
    var remainingMinutes: Int = 0
    var packages: [Package] = []
    var isPurchasing: Bool = false
    var errorMessage: String?

    #if DEBUG
    /// DEBUG-only: minutes per macOS store product id, for the StoreKit-direct
    /// fallback (`storeKitProducts`).
    static let fallbackProductMinutes: [String: Int] = [
        "extra_3_hours": 180, "extra_10_hours": 600, "extra_25_hours": 1500,
    ]
    /// DEBUG-only: products loaded straight from StoreKit when RevenueCat returns no
    /// packages — e.g. a local `.storekit` config used to generate the App Store IAP
    /// review screenshot, or a transient RevenueCat outage. NEVER used in Release,
    /// where the paywall renders only RevenueCat packages (so we never sell via a
    /// path that doesn't credit the `Min` balance). See `loadStoreKitFallback`.
    var storeKitProducts: [StoreKit.Product] = []
    #endif

    // MARK: - Internal state (not observed)

    @ObservationIgnored private var isRefreshing = false
    /// Serializes the single deduction sender so a session-stop flush and a
    /// concurrent `refreshStatus()` flush never send the same checkpoint twice.
    /// The class is `@MainActor`, so a plain flag set before the network await is
    /// sufficient.
    @ObservationIgnored private var isFlushingPending = false
    /// Reference count of open metered windows (a live cloud session AND/OR a cloud
    /// re-transcription can be active at once). While > 0, the foreground refresh
    /// skips its flush so the crash-recovery checkpoint isn't flushed mid-window
    /// (which would double-deduct). A plain Bool would let whichever window ends
    /// FIRST clear the flag out from under the other; the count keeps it held until
    /// all windows close. See `beginMeteredWindow`/`endMeteredWindow`.
    @ObservationIgnored private var meteredWindowCount = 0

    /// True while any metered window is open.
    var isTranscriptionSessionActive: Bool { meteredWindowCount > 0 }

    /// Opens a metered window (balanced by `endMeteredWindow`).
    func beginMeteredWindow() { meteredWindowCount += 1 }

    /// Closes a metered window; never underflows below zero.
    func endMeteredWindow() { meteredWindowCount = max(0, meteredWindowCount - 1) }
    @ObservationIgnored private let deduction = MacMinuteDeductionService()

    // MARK: - Computed

    /// Access is gated purely on the remaining-minute balance. Returns true while
    /// the balance is still loading so a cold launch never shows a false paywall.
    var hasAccess: Bool {
        if loadState != .loaded { return true }
        return remainingMinutes > 0
    }

    /// Pre-record gate. Offline (non-metered) sessions are always allowed;
    /// metered (cloud) sessions require a positive balance. Loads the balance
    /// first if it hasn't resolved yet, so the decision is never made on a stale
    /// or zero-by-default value.
    func canStartSession(metered: Bool) async -> Bool {
        guard metered else { return true }
        if loadState != .loaded { await refreshStatus() }
        return hasAccess
    }

    /// Whether the balance covers `minutes` of metered use, accounting for unsent
    /// pending deductions. Unlike a live session (which can pause at 0), a batch
    /// re-transcription can't stop mid-job, so it must gate on the WHOLE estimated
    /// cost up front rather than merely balance > 0 (#245 review). Loads the balance
    /// first if it hasn't resolved yet.
    func canAfford(minutes: Int) async -> Bool {
        guard minutes > 0 else { return true }
        // Always refresh so `remainingMinutes` is the raw server balance (not a
        // transiently locally-deducted value) and `pendingMinutes` is settled —
        // otherwise a just-ended live session's minutes are counted twice here (once
        // baked into the local `remainingMinutes`, once still in `pendingMinutes`) and
        // wrongly block re-transcription (#245 review). Safe: this is called before any
        // re-transcription metered window opens, so the refresh flushes pending too.
        await refreshStatus()
        // Fail OPEN if the balance never resolved (e.g. RevenueCat not configured in a
        // dev build), mirroring `hasAccess` — don't block on a default-zero balance.
        guard loadState == .loaded else { return true }
        return (remainingMinutes - pendingMinutes) >= minutes
    }

    // MARK: - RevenueCat configuration

    private var revenueCatAPIKey: String? {
        guard
            let key = Bundle.main.infoDictionary?["REVENUECAT_API_KEY_MACOS"] as? String,
            !key.isEmpty
        else { return nil }
        return key
    }

    /// Configures Purchases with the Firebase uid on the first call, logs in
    /// thereafter. No-ops (with a warning) when the macOS RC key isn't set, so a
    /// dev build without it still runs — billing is simply inert. Called from
    /// `MacAuthManager.applyFirebaseProfile` on every sign-in + launch restore.
    func configure(userID: String) {
        if Purchases.isConfigured {
            Task {
                do {
                    let (_, created) = try await Purchases.shared.logIn(userID)
                    print("✅ RC logIn: userID=\(userID), newUser=\(created)")
                } catch {
                    print("❌ RC logIn failed: \(error)")
                }
                await self.loadInitialState()
            }
            return
        }
        guard let apiKey = revenueCatAPIKey else {
            print("⚠️ REVENUECAT_API_KEY_MACOS not set — billing disabled.")
            return
        }
        Purchases.configure(
            with: .builder(withAPIKey: apiKey).with(appUserID: userID).build()
        )
        Task { await self.loadInitialState() }
    }

    /// Fetches the balance + offerings right after (re)configuration. Driven by
    /// `configure`, which the auth listener calls on every sign-in and launch
    /// restore — so there's no cold-launch race with the app's own `.task`.
    private func loadInitialState() async {
        await refreshStatus()
        await loadOfferings()
    }

    /// Logs the RevenueCat user out on sign-out (best-effort).
    func logOut() {
        guard Purchases.isConfigured else { return }
        Task {
            do {
                _ = try await Purchases.shared.logOut()
            } catch {
                print("❌ RC logOut failed: \(error)")
            }
        }
    }

    // MARK: - Local deduction (in-memory, this session only)

    func deductMinutesLocally(_ minutes: Int) {
        guard minutes > 0 else { return }
        remainingMinutes = max(0, remainingMinutes - minutes)
        print("[MinutesSync] Local deduct: \(minutes) min, remaining=\(remainingMinutes)")
    }

    // MARK: - Pending deduction (forwarded to MacMinuteDeductionService)

    var pendingMinutes: Int { deduction.pendingMinutes }

    func savePendingDeduction(_ minutes: Int) { deduction.savePending(minutes) }

    /// Charges `minutes` for an OFF-session cloud operation (post-session
    /// re-transcription, #245). Sent as a STANDALONE deduction — deliberately NOT via
    /// the shared `pending_minutes_to_deduct` checkpoint, which belongs to the LIVE
    /// session's crash-recovery accumulator. Entangling them let a re-transcription
    /// finishing mid-live-session flush the live checkpoint early, after which
    /// `endBilling` re-sent the live total and double-charged it (#245 review). Drops
    /// the local balance immediately for instant UI; a failed send is best-effort (no
    /// crash-recovery retry — acceptable for a value-add re-transcription; the next
    /// balance refresh reconciles).
    func chargeMinutes(_ minutes: Int) async {
        guard minutes > 0 else { return }
        deductMinutesLocally(minutes)
        guard let userID = MacAuthManager.shared.userID else {
            print("[MinutesSync] Re-transcription charge skipped — no userID")
            return
        }
        do {
            try await deduction.send(minutes: minutes, userID: userID)
            print("[MinutesSync] Re-transcription charged: \(minutes) min")
        } catch {
            print("[MinutesSync] Re-transcription charge failed (not retried): \(error)")
        }
    }

    /// Drops any unflushed pending deduction without sending it (used on sign-out).
    func clearPendingDeduction() { deduction.clearPending() }

    /// Single guarded send path shared by session-stop and `refreshStatus()`. The
    /// pending value is cleared only after a successful send, so a crash mid-send
    /// retries on the next launch.
    func flushPendingDeductionIfNeeded() async {
        guard !isFlushingPending else { return }
        let pending = deduction.pendingMinutes
        guard pending > 0 else { return }
        guard let userID = MacAuthManager.shared.userID else {
            print("[MinutesSync] Cannot flush pending — no userID")
            return
        }
        isFlushingPending = true
        defer { isFlushingPending = false }
        do {
            try await deduction.send(minutes: pending, userID: userID)
            deduction.clearPending()
            print("[MinutesSync] Pending deduction flushed: \(pending) min")
        } catch {
            print("[MinutesSync] Failed to flush pending: \(error) — will retry next launch")
        }
    }

    // MARK: - Refresh

    /// Refresh on foreground return so gating never runs on a stale balance.
    /// Skipped while a metered session is active (see `isTranscriptionSessionActive`).
    func refreshStatusOnForeground() async {
        guard !isTranscriptionSessionActive else {
            print("[MinutesSync] Skipping foreground refresh — session active")
            return
        }
        await refreshStatus()
    }

    func refreshStatus() async {
        guard Purchases.isConfigured else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        // Don't clobber an already-resolved balance back to `.loading`: a routine
        // (foreground/manual) refresh must keep `loadState == .loaded` so the
        // pre-record gate fails CLOSED on the last-known balance rather than
        // fail-open — which would let a 0-balance metered session start uncapped
        // when Record is tapped during a concurrent refresh (#242 review).
        if loadState != .loaded { loadState = .loading }
        defer { isRefreshing = false }

        // Never flush the crash-recovery checkpoint while a metered session is
        // active: the single teardown flush in `endBilling` is the sole send, and an
        // early flush here (e.g. the Settings "Refresh balance" button, or a
        // re-sign-in refresh) would be re-sent at stop and double-charge (#242 review).
        if !isTranscriptionSessionActive {
            await flushPendingDeductionIfNeeded()
        }
        do {
            try await refreshMinuteBalance()
        } catch {
            print("[MinutesSync] Balance fetch failed, showing last known value: \(error)")
        }
        loadState = .loaded
    }

    /// Reads the authoritative balance from the `Min` virtual currency. Internal
    /// (not private) so the `+Offerings` extension's `purchase(_:)` can call it.
    func refreshMinuteBalance() async throws {
        Purchases.shared.invalidateVirtualCurrenciesCache()
        let virtualCurrencies = try await Purchases.shared.virtualCurrencies()
        remainingMinutes = virtualCurrencies.all[Self.currencyCode]?.balance ?? 0
        print("[MinutesSync] RC balance=\(remainingMinutes)")
    }
}
