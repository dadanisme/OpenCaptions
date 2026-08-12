# macOS Offline Mode: binary online/offline, Nemotron-backed

> **⚠️ HISTORICAL — superseded 2026-08-12.** The binary Offline Mode toggle this
> note introduces was replaced by a three-way Transcription Engine picker
> (Soniox/Nemotron/Parakeet) — the same shape this note itself replaced a day
> earlier (see **`docs/2026-07-10-macos-on-device-engines.md`**, which stays
> current for the underlying engine implementations). See
> **`docs/2026-08-12-macos-transcription-engine-selector.md`**. Decisions 4
> (Firestore sync of the preference) and the Firestore-rules **Risk** section
> below are additionally stale on their own terms — `docs/2026-08-10-remove-accounts-and-firestore.md`
> removed Firestore sync of local preferences entirely.

**Date:** 2026-07-10
**Builds on:** `docs/2026-07-10-macos-on-device-engines.md`

## Context

Open Captions gained a 3-way engine picker (Soniox / Parakeet / Nemotron) just one
day earlier. We now add a user-facing **Offline Mode** that runs transcription
entirely on-device. Rather than keep a free engine selector, we collapse it into a
**binary online/offline toggle** — the product wants "online vs offline", not
per-engine choice.

Onboarding / skip-login integration is **out of scope** here — no
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
   This is **not** routed through the session `createDoc`/`updateDoc` helpers — they are
   session-scoped and own the create-once audit stamping. (Originally they were also
   gated behind the `sessionSharing` feature flag; that flag was removed 2026-07-27 —
   see `docs/2026-07-27-remove-feature-flags.md`.)

## Risk

Firestore rules live in the backend Cloud Functions project. The `users/{uid}` write of
`isOfflineModeEnabled` needs the ruleset to permit the owner to write that field; if
rejected it fails silently (logged). Follow up with a rules change in the backend Cloud Functions project if needed.

## Files

- `LiveSessionStore.swift` — `transcriptionEngineKey` → `offlineModeKey`
  (`opencaptions.offlineMode.enabled`, default `false`, registered in `OpenCaptionsApp.init`).
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

Build the **OpenCaptions** scheme in Xcode. Settings → Recording: engine picker gone; one
Offline Mode section. Before download, the row shows a prominent Download button (progress
while fetching); after it completes the row becomes a plain on/off toggle. Enable → record
→ Preparing overlay → single-stream on-device transcript with no network. Saved session
while offline: existing summary shows; no-summary session shows the offline state;
Re-summarize + Share disabled/hidden. Turn off → cloud transcription + summaries return.
Signed in: flip the toggle and confirm `users/{uid}.isOfflineModeEnabled` +
`updatedAt`/`updatedBy` update.
