# macOS Consumable-Hours Billing (rate limiting + minute metering)

**Date:** 2026-07-10
**Topic:** macOS: rate limiting, consumable-hours billing, and per-provider BYOK
**Type:** Implementation. Adds the consumable-minutes billing model to Open Captions.
**Scope note:** **BYOK is out of scope** for this change (dropped per product decision).
Offline Mode is the free path instead (see below).

## Context

Open Captions shipped without any metering — cloud transcription was unlimited and free.
The distribution decision (`docs/2026-07-10-macos-distribution.md`) named this
work as its follow-up: add RevenueCat, build `SubscriptionManager` /
`MinuteDeductionService`, configure `Purchases` with the Firebase uid, add a paywall,
and gate session start + minute deduction. This change does exactly that.

## Decisions

### 1. Only cloud (Soniox) sessions are metered; Offline Mode is free
The engine is chosen at `MacTranscriptionViewModel.start()` from the Offline Mode
toggle: off → `.soniox` (cloud), on → `.nemotron` (on-device). Only `.soniox` incurs a
Soniox cost, so **only cloud sessions gate on the balance and deduct minutes**.
On-device (Offline Mode) sessions never touch billing — this is the free path that
replaces the dropped BYOK escape hatch, and it matches the actual cost model. Metering
keys off `!kind.isOnDevice`.

### 2. RevenueCat credits offering — balance keyed by Firebase uid
The `credits` offering's packages `starter` / `plus` / `pro` carry the macOS
products (`extra_3_hours` / `extra_10_hours` / `extra_25_hours`); RevenueCat serves the
right store product per package. The `Min` virtual-currency balance is keyed per
Firebase uid (project + currency + App User ID), so a purchase credits that user's
balance. macOS reads `REVENUECAT_API_KEY_MACOS` (the macOS store app's public SDK key).

Minutes-per-pack is mapped by **package identifier** (`starter`/`plus`/`pro` →
180/600/1500), which is platform-agnostic, rather than by product id.

### 3. The billing clock lives on the view model, not the view
A session **outlives its window** (owned by `LiveSessionStore`, kept awake by its
`beginActivity` App-Nap assertion), so a view-owned timer would die on window close.
The clock therefore lives on `MacTranscriptionViewModel` (`+Billing` extension), driven
from `start`/`pause`/`resume`/`stop`/`discard`/`failSession`. It's a `RunLoop.main`
1 s timer (kept alive by the existing assertion) that increments `billedSeconds` only
while `isRunning` — so paused seconds don't burn balance.

### 4. Deduction only at teardown; rounded up; crash-recovery checkpoint
Network deduction happens **once**, at `stop()`/`discard()` — never per-minute —
sending `sessionBaselinePending + ceil(billedSeconds/60)` as `{user_id, minutes}` to
`DEDUCT_MINUTES_URL` (bearer `SUMMARIZE_API_TOKEN`). A 30 s local
UserDefaults checkpoint (`pending_minutes_to_deduct`) gives crash recovery; it's flushed
on the next launch via `refreshStatus()` and cleared only after a successful send.
`failSession` freezes the clock but does **not** deduct — the eventual Stop & Save does
the single deduction, avoiding a double-charge.

### 5. Built on `@Observable`, not `ObservableObject`
`MacSubscriptionManager` is an `@Observable @MainActor` singleton (matching
`MacAuthManager`). Not included: a legacy `hasActiveSubscription`/migration-notice path
(there are no legacy macOS subscribers) and analytics (Open Captions has no Firebase
Analytics). The paywall is hand-rolled native SwiftUI (`MacPaywallView`), not
RevenueCatUI, which keeps RevenueCatUI unlinked on macOS.

## Enforcement flow

- **Pre-record gate** (`MacSubscriptionManager.canStartSession(metered:)`): metered
  starts require `hasAccess` (positive balance, after ensuring the balance is loaded);
  Offline is always allowed. Blocked starts present `MacPaywallView` instead of
  recording — from `TranscriptionsScreen.startNewRecording` (in-window) and
  `LiveSessionStore.startHeadlessRecording` (menu-bar; also raises the window).
- **In-session**: `<5 min` remaining → a low banner; `0` → graceful pause
  (`handleOutOfTime`) + out banner, with the timer kept alive so an in-session top-up
  recomputes the budget and resumes. The cap is enforced via an explicit
  `billingCapActive` flag (true when the balance was loaded at start), **not** by
  overloading `sessionAllowedSeconds == 0` — so a genuinely-0 budget (e.g. a prior
  failed flush left the gross balance fully owed) fires out-of-time immediately instead
  of recording uncapped.
- **Foreground refresh**: `NSApplication.didBecomeActiveNotification` →
  `refreshStatusOnForeground()`. The pending-checkpoint flush is guarded **inside**
  `refreshStatus()` itself (`!isTranscriptionSessionActive`), so no refresh path — the
  Settings "Refresh balance" button, or a re-sign-in refresh — can flush the crash
  checkpoint mid-session and double-deduct at stop. `refreshStatus()` also never
  downgrades an already-`.loaded` balance to `.loading`, so the gate fails closed on the
  last-known balance during a concurrent refresh.
- **Sign-out mid-session**: `MacAuthManager.signOut()` calls
  `LiveSessionStore.discardActiveSession()` first, so a window-independent metered
  session can't keep running past sign-out and flush its minutes against the next user.

## Files

- **New**: `Utility/MacSubscriptionManager.swift` (+`+Offerings`),
  `Utility/MacMinuteDeductionService.swift`, `ViewModel/MacTranscriptionViewModel+Billing.swift`,
  `Views/MacPaywallView.swift`, `Views/MacUsageSettingsView.swift`,
  `Views/MacLiveTranscriptionView+Billing.swift`, `Views/MacLiveTranscriptionView+Speakers.swift`
  (split out to hold the line limit), `OpenCaptions/OpenCaptions.storekit` (local StoreKit test file).
- **Edited**: `project.pbxproj` (link RevenueCat to OpenCaptions), `OpenCaptions-Info.plist`
  (`REVENUECAT_API_KEY_MACOS`, `DEDUCT_MINUTES_URL`), `OpenCaptionsApp.swift` (env + foreground
  refresh), `MacAuthManager.swift` (configure/logout RevenueCat with the uid),
  `MacTranscriptionViewModel.swift` (billing state + lifecycle hooks), `LiveSessionStore.swift`
  (headless gate + `pendingPaywall`), `TranscriptionsScreen.swift` (in-window gate + paywall),
  `MacLiveTranscriptionView.swift` (banner inset + paywall sheet), `MacSettingsView.swift`
  (Usage tab), `SidebarProfileFooter.swift` (balance chip).

## External setup (done in dashboards)

- App Store Connect: macOS app record + 3 consumables `extra_3_hours`/`extra_10_hours`/`extra_25_hours`.
- RevenueCat: macOS store app added to the project; products attached to the
  `credits` offering packages `starter`/`plus`/`pro`; `Min` virtual currency granted.
- **Config**: add `REVENUECAT_API_KEY_MACOS = appl_…` (the macOS RC public SDK key) to the
  git-ignored `Config.xcconfig`. `DEDUCT_MINUTES_URL` + `SUMMARIZE_API_TOKEN` already exist.

## Testing notes

- The local `OpenCaptions.storekit` simulates the **purchase** UI/flow but not the `Min`
  balance credit (virtual currency is computed by the RevenueCat backend). To exercise
  the full balance/deduction loop, use RevenueCat **sandbox** purchases, not the local
  config file.
- **IAP review screenshot**: attach `OpenCaptions/OpenCaptions.storekit` in the scheme
  (Run → Options → StoreKit Configuration) and open the paywall. `MacPaywallView` has a
  **DEBUG-only StoreKit-direct fallback** (`MacSubscriptionManager.loadStoreKitFallback`)
  that renders products straight from StoreKit when RevenueCat returns no packages, so
  the paywall populates for the screenshot even if the RevenueCat offering isn't wired
  up yet. It's `#if DEBUG` only — Release always renders RevenueCat packages so a
  purchase can never bypass the `Min` credit. The fallback logs
  `[Billing] StoreKit fallback loaded N product(s)`; N == 0 means the StoreKit config
  isn't active or the product ids don't match.
- Verify: Offline Mode records free (no gate/deduction); a Soniox session deducts
  `ceil(minutes)` on stop and POSTs to `DEDUCT_MINUTES_URL`; a 0 balance shows the paywall
  pre-record; mid-session exhaustion pauses + banners; a top-up resumes; a mid-session
  kill flushes the checkpoint on next launch.

## Deferred

BYOK (per-provider keys), account deletion / password reset, Firestore share analytics,
and localization of the new billing strings (macOS UI is still hardcoded English).
