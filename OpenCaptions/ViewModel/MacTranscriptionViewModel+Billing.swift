//
//  MacTranscriptionViewModel+Billing.swift
//  OpenCaptions
//
//  Minute metering for cloud (Soniox) sessions. Distilled from the iOS
//  LiveTranscriptionView billing logic, but hoisted onto the view model (not a
//  SwiftUI view) because a macOS session outlives its window — the billing clock
//  must survive a window close, just like the audio + socket do.
//
//  Rules (mirror iOS):
//  - Only metered (cloud) sessions count; Offline Mode is free.
//  - A 1 s clock accumulates `billedSeconds` only while RUNNING (paused seconds
//    don't burn balance), and it's kept alive by LiveSessionStore's App-Nap
//    assertion so a backgrounded/occluded window keeps enforcing.
//  - Local UserDefaults checkpoint every 30 s for crash recovery.
//  - At <5 min remaining → a low banner; at 0 → graceful pause + out banner (the
//    timer stays alive so a top-up can resume).
//  - Network deduction happens ONCE, at teardown (stop/discard), rounding up to
//    the whole minute; never per-minute.
//

import Foundation

/// Live billing banner state for the recording UI.
enum BillingBanner: Equatable {
    case none
    /// Fewer than 5 minutes of budget remain (associated: whole minutes left).
    case low(Int)
    /// Budget exhausted — recording paused until a top-up.
    case out
}

extension MacTranscriptionViewModel {

    /// Whole minutes used so far this session (rounded up; a 1 s session = 1 min).
    var minutesUsed: Int { Int(ceil(Double(billedSeconds) / 60.0)) }

    // MARK: - Start

    /// Begins metering for a metered (cloud) session. No-ops for Offline Mode.
    /// Captures the crash-recovery carryover and the per-session cap, then starts
    /// the 1 s clock.
    @MainActor
    func startBilling(metered: Bool) {
        isMeteredSession = metered
        billingBanner = .none
        lowWarningShown = false
        billedSeconds = 0
        sessionBaselinePending = 0
        sessionAllowedSeconds = 0
        billingCapActive = false
        guard metered else { return }

        let billing = MacSubscriptionManager.shared
        billing.beginMeteredWindow()
        sessionBaselinePending = billing.pendingMinutes
        let budget = billing.remainingMinutes - sessionBaselinePending
        sessionAllowedSeconds = max(0, budget) * 60
        // Enforce the cap only when the balance actually resolved. If it hadn't
        // (cold-launch fail-open), record uncapped but still deduct at stop. A LOADED
        // balance with budget 0 (e.g. a prior failed flush left the gross balance
        // fully owed) is a real exhaustion → cap active → billingTick fires out-of-time
        // on the first tick instead of treating 0 as "unlimited" (#242 review).
        billingCapActive = billing.loadState == .loaded
        startBillingTimer()
    }

    // MARK: - Clock

    private func startBillingTimer() {
        billingTimer?.invalidate()
        // RunLoop.main + `.common` so it keeps firing during UI tracking; the
        // App-Nap assertion (LiveSessionStore) keeps it alive when backgrounded.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.billingTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        billingTimer = timer
    }

    /// Invalidates the clock without deducting (used by `failSession`; the eventual
    /// `stop`/`discard` does the single deduction).
    @MainActor
    func stopBillingTimer() {
        billingTimer?.invalidate()
        billingTimer = nil
    }

    @MainActor
    private func billingTick() {
        guard isMeteredSession, isRunning else { return }  // paused → don't burn
        billedSeconds += 1

        // Crash-recovery checkpoint every 30 s (local only; no network).
        if billedSeconds % 30 == 0 {
            MacSubscriptionManager.shared.savePendingDeduction(sessionBaselinePending + minutesUsed)
        }

        // Cap enforcement — only when the cap is active (balance was loaded at start).
        // With the cap active, sessionAllowedSeconds == 0 means exhausted, so the
        // check below fires out-of-time immediately rather than running uncapped.
        guard billingCapActive else { return }
        let remaining = sessionAllowedSeconds - billedSeconds
        if remaining <= 0 {
            handleOutOfTime()
        } else if remaining <= 300, !lowWarningShown {
            lowWarningShown = true
            billingBanner = .low(Int(ceil(Double(remaining) / 60.0)))
        }
    }

    /// Budget exhausted: pause gracefully (keeps the socket + clock alive so a
    /// top-up can resume) and show the out banner. Fires once per budget.
    @MainActor
    private func handleOutOfTime() {
        guard billingBanner != .out else { return }
        billingBanner = .out
        pause()
    }

    // MARK: - Top-up

    /// After an in-session purchase, recompute the cap against the fresh balance and
    /// clear the banner. The caller resumes recording. `billedSeconds` keeps its
    /// value, so `remaining = sessionAllowedSeconds - billedSeconds` stays correct
    /// (the purchase added to the balance the used minutes will be deducted from).
    @MainActor
    func recomputeBudgetAfterTopUp() {
        guard isMeteredSession else { return }
        let billing = MacSubscriptionManager.shared
        let budget = billing.remainingMinutes - sessionBaselinePending
        sessionAllowedSeconds = max(0, budget) * 60
        lowWarningShown = false
        billingBanner = .none
    }

    // MARK: - End

    /// Stops the clock and deducts the metered minutes used (baseline carryover +
    /// this session's usage, rounded up). No-op for Offline Mode. Deduction is
    /// two-phase: a local in-memory drop for instant UI, plus a persisted checkpoint
    /// flushed to the backend (cleared only on a successful send).
    @MainActor
    func endBilling() {
        stopBillingTimer()
        guard isMeteredSession else { return }
        isMeteredSession = false
        billingBanner = .none

        let billing = MacSubscriptionManager.shared
        billing.endMeteredWindow()

        let total = sessionBaselinePending + minutesUsed
        guard total > 0 else { return }
        billing.savePendingDeduction(total)
        billing.deductMinutesLocally(total)
        Task { await billing.flushPendingDeductionIfNeeded() }
    }
}
