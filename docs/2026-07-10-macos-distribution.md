# macOS Distribution — Signing, Notarization/MAS, StoreKit Products

**Date:** 2026-07-10
**Issue:** #177 (epic #103) — "macOS: distribution — signing, notarization/MAS, StoreKit products"
**Type:** Decision + external-config record. **No app-code changes** — the issue is
explicitly scoped as *"external-config + signing decisions distinct from the app code."*
The Swift work to actually charge on macOS (RevenueCat SDK + paywall + minute gating)
is a **separate implementation issue** (see **Out of scope**).

## TL;DR decisions

| Question | Decision |
|---|---|
| Distribution channel | **Mac App Store** (not Developer-ID / DMG) |
| Bundle id | **`com.muhammadramdan.OgmoMac`** |
| Signing team | **`C4SQMCY5WT`** (Ramdan's account — the currently committed config) |
| Hardened Runtime | **Not enabled** — not required for MAS; only Developer-ID/notarized apps need it |
| Notarization | **Not needed** — the App Store review pipeline handles it |
| Entitlements | **Finalized as-is** — the current `OgmoMac.entitlements` set is MAS-clean; no change |
| Monetization products | **Consumable "minutes" IAPs** (`com.ogmo.minutes_180/600/1500`), *not* the `student`/`studentplus` subscriptions the issue text names (stale — see below) |

## 1. Distribution channel: Mac App Store

**Chosen: Mac App Store.** Rationale, strongest first:

1. **StoreKit in-app purchases require App Store distribution.** Ogmo monetizes by
   selling **consumable minute packs** through StoreKit (via RevenueCat). A
   Developer-ID app distributed outside the App Store (DMG/direct download)
   **cannot use StoreKit for IAP** — it would have to switch to a non-Apple payment
   path (Stripe / RevenueCat Web Billing), which is a different product and backend.
   Because the monetization model is StoreKit-based, **MAS is effectively forced**,
   not merely preferred.
2. **The app is already designed to be App-Store-safe.** No private APIs; App Sandbox
   respected; entitlements minimal and justified. The one MAS-hostile entitlement that
   ever existed — a `temporary-exception.mach-lookup.global-name` for
   `com.apple.audioanalyticsd` — was **already removed** because the Mac App Store
   rejects it under Guideline 2.4.5(i) (see `docs/2026-07-06-macos-mic-system-audio-fix.md`).
3. **No notarization / Hardened Runtime overhead.** MAS builds are signed with an
   Apple Distribution certificate and a Mac App Store provisioning profile and
   submitted to App Review; they are **not** run through the Developer-ID notary
   service, and they do **not** enable the Hardened Runtime capability.

**Trade-off accepted:** App Review latency, Apple's commission, and permanent App
Sandbox confinement — in exchange for the only viable StoreKit path and a single,
familiar distribution/update channel shared with the iOS app's audience.

## 2. Signing & Hardened Runtime

Current committed build settings for the `OgmoMac` target (verified in
`unmute.xcodeproj/project.pbxproj`):

| Setting | Value |
|---|---|
| `CODE_SIGN_STYLE` | `Automatic` |
| `DEVELOPMENT_TEAM` | `C4SQMCY5WT` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.muhammadramdan.OgmoMac` |
| `PRODUCT_NAME` | `Ogmo` (artifact is `Ogmo.app`) |
| `CODE_SIGN_ENTITLEMENTS` | `OgmoMac.entitlements` (repo root) |
| `MACOSX_DEPLOYMENT_TARGET` | `14.4` |
| `INFOPLIST_KEY_LSApplicationCategoryType` | `public.app-category.productivity` (required for a MAS listing) |
| `ENABLE_HARDENED_RUNTIME` | *(unset — 0 occurrences in the project)* |

- **Hardened Runtime stays OFF.** It is a Developer-ID/notarization requirement, not a
  MAS one. Leaving it unset is correct; do **not** add it.
- **Signing for release** needs, one-time in the Apple Developer account
  `C4SQMCY5WT`: an **Apple Distribution** certificate and a **Mac App Store**
  provisioning profile for `com.muhammadramdan.OgmoMac`. With `CODE_SIGN_STYLE =
  Automatic`, Xcode provisions both when you archive while signed into that account.
- **Upload path:** Xcode Organizer → *Distribute App → App Store Connect*, or
  Transporter, or `xcrun altool`/App Store Connect API from CI.

## 3. Entitlements — finalized (no change)

The current `OgmoMac.entitlements` is already the correct, minimal MAS set. Each key
and its MAS standing:

| Entitlement / key | Purpose | MAS standing |
|---|---|---|
| `com.apple.security.app-sandbox` | Sandbox | **Required** for MAS ✓ |
| `com.apple.security.device.audio-input` | Mic tap **and** Core Audio process-tap system-audio path | Allowed ✓ |
| `com.apple.security.network.client` | Soniox WSS, summary POST, Google Sign-In `ASWebAuthenticationSession` | Allowed ✓ |
| `com.apple.security.files.user-selected.read-write` | PDF export via `NSSavePanel` (Powerbox) | Allowed ✓ |
| `keychain-access-groups` = `$(AppIdentifierPrefix)com.muhammadramdan.OgmoMac` | FirebaseAuth keychain persistence (else `errSecMissingEntitlement -34018`) | Allowed ✓ |
| `com.apple.developer.applesignin` = `["Default"]` | Sign in with Apple (button currently hidden, capability retained) | Allowed ✓ |

Info.plist (`OgmoMac-Info.plist`) items that matter for the store:

- `ITSAppUsesNonExemptEncryption = false` — only standard TLS; suppresses the
  per-upload export-compliance question. ✓
- `NSAudioCaptureUsageDescription` — drives the **Audio Recording** grant
  (`kTCCServiceAudioCapture`) used by the Core Audio **process-tap** system-audio
  capture (this is the public API + user-consent path, **not** ScreenCaptureKit /
  Screen Recording). App-Store-permissible; **App Review may ask for justification** —
  the answer is "transcribing the user's own meeting/session audio," and capture only
  begins after the user grants the prompt.

**Nothing to add or remove for MAS.**

## 4. Monetization / StoreKit products

### The issue text is stale — corrected model

Issue #177 says *"enable the `student` / `studentplus` subscription products
(entitlement `pro_features`)."* That predates a billing migration. The app has since
**moved off auto-renewable subscriptions**:

- `SubscriptionManager` (iOS) now sells **consumable minute packs** (the **"credits"**
  offering) which grant a RevenueCat **"Min" virtual currency**. Access is gated
  **purely on the remaining-minute balance** — the code comment is explicit:
  *"There is no subscription/entitlement."* There is **no `pro_features` entitlement**.
- The legacy `com.student.monthly` / `com.studentplus.monthly` auto-renewables still
  exist only to target a one-time migration notice for pre-migration subscribers; they
  do **not** gate access and should **not** be recreated for macOS.

**Products to enable for macOS** (the consumables, from `unmute/product.storekit`):

| Product ID | Pack | Price |
|---|---|---|
| `com.ogmo.minutes_180` | 3 hours | $1.99 |
| `com.ogmo.minutes_600` | 10 hours | $4.99 |
| `com.ogmo.minutes_1500` | 25 hours | $9.99 |

### Cross-account nuance (important)

OgmoMac ships under **Ramdan's account (`C4SQMCY5WT`, `com.muhammadramdan.OgmoMac`)**,
which is **separate** from the iOS app's org account (`YN8NVQ69WY`,
`com.wentao.unmute`). Consequences:

- The macOS IAP products are created under **Ramdan's** App Store Connect app record.
  IAP product IDs are unique per account, so the **same ID strings can be reused**
  (different account than iOS).
- **To share the "Min" balance across iOS + macOS per user** (App User ID = Firebase
  uid, same Firebase project → same uid namespace), the macOS app must be added to the
  **same RevenueCat project** as iOS. RevenueCat supports multiple store apps per
  project — even under different Apple accounts — each configured with its own store
  credentials; the customer's virtual-currency balance is **project-level**, so a
  purchase on either platform credits the same balance. **→ Verify this cross-account
  setup in the RevenueCat dashboard** when wiring it up; if it turns out a shared
  balance isn't achievable across the two Apple accounts, the fallback is a
  per-platform balance (worse UX) or moving OgmoMac under the org account.

## 5. CI for the macOS build

- **Current state:** the only workflow is `.github/workflows/file-length-check.yml`.
  There is **no** build/archive/upload CI for any target.
- **Recommended MAS pipeline** (documented, **not yet wired** — see why below):
  `xcodebuild archive` → `xcodebuild -exportArchive` with method `app-store` → upload
  via the **App Store Connect API key** (issuer id + key id + `.p8`) or Transporter.
  **No notarization step** (MAS). CI signing needs the Apple Distribution cert + Mac
  App Store profile imported into a temporary keychain (e.g. via Fastlane `match`),
  all supplied as GitHub Actions secrets.
- **Why not add the workflow file in this change:** it cannot run without the signing
  cert, provisioning profile, and App Store Connect API key provisioned as repo
  secrets — it would fail on every push until then. Add it as a follow-up once those
  secrets exist. (Local release builds are done from Xcode per team preference; CI is
  opt-in.)

## 6. External setup checklist (done outside this repo)

Performed by the account owner in dashboards — **not** code:

- **Apple Developer (`C4SQMCY5WT`):** App ID `com.muhammadramdan.OgmoMac` already
  exists (auth work); create an **Apple Distribution** certificate and a **Mac App
  Store** provisioning profile.
- **App Store Connect:** create the macOS app record for `com.muhammadramdan.OgmoMac`;
  category = Productivity; fill metadata + privacy nutrition labels (microphone, audio
  capture, account/email); create the three **consumable** IAPs above; export
  compliance already answered via the plist.
- **RevenueCat:** add the **Mac App Store app** to the existing (iOS) project; supply
  its App Store Connect credentials; map the three products into the **"credits"**
  offering and grant the **"Min"** virtual currency (mirror iOS). Record the macOS
  RevenueCat API key for the future billing port.
- **Firebase:** the macOS app (`com.muhammadramdan.OgmoMac`) is already registered
  (see `docs/2026-07-05-macos-auth-and-scoping.md`).

## 7. Acceptance-criteria status

- [x] **Distribution channel chosen and documented** — Mac App Store; this doc.
- [~] **A signed macOS build can be produced** — unblocked: archive under
  `C4SQMCY5WT` once the Apple Distribution cert + Mac App Store profile exist
  (external). No notarization needed.
- [~] **Purchases/paywall work on macOS with per-platform products enabled** —
  #177 **decides and documents** monetization and unblocks the external product
  setup. Actually charging requires **both** (a) the external ASC/RC config above and
  (b) the **billing-port code** (below), which is a separate issue.

## Out of scope (separate follow-ups)

- **Billing port to OgmoMac** — add RevenueCat (+ RevenueCatUI) to the target, port
  `SubscriptionManager` / `MinuteDeductionService`, configure `Purchases` with the
  Firebase uid, add a paywall, and gate `MacTranscriptionViewModel` session start +
  minute deduction. OgmoMac currently has **no billing** (deferred at MVP,
  `docs/2026-07-04-macos-standalone-mvp.md`). This is Swift work, not #177.
- **macOS release CI workflow** — add once signing secrets are provisioned.
- **Confirm RevenueCat cross-account shared-balance feasibility** (§4).
