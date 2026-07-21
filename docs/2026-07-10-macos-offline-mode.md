# macOS Offline Mode: binary online/offline, Nemotron-backed (#274)

**Date:** 2026-07-10
**Issue:** #274 (macOS: add offline mode) — epic #103
**Builds on:** #175 / `docs/2026-07-10-macos-on-device-engines.md`

## Context

`OgmoMac` gained a 3-way engine picker (Soniox / Parakeet / Nemotron) in #175 just one
day earlier. #274 asks for a user-facing **Offline Mode** that runs transcription
entirely on-device. Rather than keep a free engine selector, we collapse it into a
**binary online/offline toggle** — the product wants "online vs offline", not
per-engine choice.

Onboarding / skip-login (the issue's #243 integration) is **out of scope** here — no
onboarding flow exists yet. This change is the in-app half only.

## Decisions

1. **Remove the engine selector; replace with an Offline Mode toggle.**
   - **Off (default)** → cloud **Soniox** (diarized) — unchanged behavior.
   - **On** → on-device **Nemotron 560 ms**, always. Nemotron is the sole live
     transcriber; there is no in-app choice of on-device engine.
   The `transcriptionEngineKey` UserDefaults key is **deleted** (no migration — a stale
   value is simply ignored; the new `offlineModeKey` defaults to `false` = online, so
   existing users keep Soniox).

2. **`MacTranscriptionEngineKind` / factory are kept as the internal engine descriptor.**
   No longer a user picker: `MacTranscriptionViewModel.start()` maps
   `isOffline ? .nemotron : .soniox`. The `.parakeet` case is retained for its
   `modelManager` (download card + the enable gate) and as the entry point for the
   upcoming offline **re-transcribe** feature — it is not built for live transcription.

3. **The Offline Mode row morphs on model download — no separate download UI.** Nemotron
   transcribes live; Parakeet TDT v2 is downloaded now but reserved for offline
   re-transcribe. The two models are an implementation detail: while they aren't both on
   disk, the "Offline Mode" row shows a **prominent Liquid Glass Download button**
   (`MacOfflineDownloadControl` in a `LabeledContent`) — or compact progress while
   downloading — that fetches both as one unit and never names a model. Once both are
   `.ready` (`offlineFilesReady`, `@Observable`-driven) the row swaps to a plain on/off
   `Toggle`. There is **no Delete** — model management (incl. removal) is coming in a
   dedicated model manager, so this control never needs a "downloaded"/delete state.

   The Download / Retry action uses `View.glassProminentButton()` → `.glassProminent` on
   macOS 26+, `.borderedProminent` below — native, not a bare link. User-facing copy names
   neither the engines nor the vendors ("cloud" vs "on this Mac, English only"); model /
   engine names appear only in code and docs. (The old per-model `MacFluidAudioModelCard`
   was deleted — unused after this.)

4. **Offline disables cloud summary GENERATION, not existing summaries.**
   There is no on-device summarizer. While offline: auto-summarize is skipped,
   Re-summarize + the empty-state Summarize button are disabled, and the empty summary
   state shows an "unavailable offline" message. An **already-generated** summary still
   renders. Share-to-web is also hidden offline (it's a network write). PDF export stays
   (local). The gate keys off the *current* device setting, so turning Offline Mode off
   restores summary generation for any session.

5. **Firestore sync of the preference (authenticated only).**
   Toggling writes `users/{uid}.isOfflineModeEnabled` via
   `FirestoreSyncService.syncOfflineMode(_:)` (new `+UserPrefs` extension). No-op when
   not signed in. Uses `setData(merge: true)` with only `updatedAt`/`updatedBy` stamped
   so the user doc's `createdAt`/`createdBy` (owned by whoever created it) are preserved.
   This is **not** routed through the session `createDoc`/`updateDoc` helpers — those are
   gated behind the `sessionSharing` flag and are session-scoped.

## Risk

Firestore rules live in the sibling **`../ogmo-cf`** repo. The `users/{uid}` write of
`isOfflineModeEnabled` needs the ruleset to permit the owner to write that field; if
rejected it fails silently (logged). Follow up with a rules change in `ogmo-cf` if needed.

## Files

- `LiveSessionStore.swift` — `transcriptionEngineKey` → `offlineModeKey`
  (`ogmo.offlineMode.enabled`, default `false`, registered in `OgmoMacApp.init`).
- `MacTranscriptionViewModel.swift` — `start()` engine resolution.
- `MacSettingsView.swift` — Recording tab: one Offline Mode section (toggle + gate +
  combined download).
- `MacOfflineDownloadControl.swift` — new; the on-the-row Download button / progress.
  `View+LiquidGlass.swift` — new `glassProminentButton()` helper.
  `MacFluidAudioModelCard.swift` — deleted (unused).
- `MacSessionDetailView.swift` — summary/share gating.
- `FirestoreSyncService.swift` (`F.isOfflineModeEnabled`) + new
  `FirestoreSyncService+UserPrefs.swift` (`syncOfflineMode`).
- `MacTranscriptionEngineKind.swift` — header comment only.

## Verification

Build the **OgmoMac** scheme in Xcode. Settings → Recording: engine picker gone; one
Offline Mode section. Before download, the row shows a prominent Download button (progress
while fetching); after it completes the row becomes a plain on/off toggle. Enable → record
→ Preparing overlay → single-stream on-device transcript with no network. Saved session
while offline: existing summary shows; no-summary session shows the offline state;
Re-summarize + Share disabled/hidden. Turn off → cloud transcription + summaries return.
Signed in: flip the toggle and confirm `users/{uid}.isOfflineModeEnabled` +
`updatedAt`/`updatedBy` update.
