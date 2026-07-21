# macOS Onboarding & Offline Guest Mode (OpenCaptions)

**Date:** 2026-07-11 · **Target:** `OpenCaptions`

## Summary

A first-run **setup assistant** for the standalone macOS app that guides a new
user through choosing how to use Open Captions, signing in (or going offline), granting
recording permissions, and picking a capture source — then drops them into the
app. It also introduces a **"use without an account" offline guest mode**, at the
user's request ("offline mode … skip login, and download models").

Before this, the app gate was a hard `if auth.isSignedIn { ContentView } else {
SignInView }` — no onboarding, and sign-in was mandatory.

## Flow

A single-card wizard (progress dots · content · Back / primary bar). Steps:

```
Welcome → Mode → { Sign in | Download } → Capture → Permissions → Ready
                    ↑ cloud     ↑ offline
```

- **Welcome** — value proposition + three feature highlights.
- **Mode** — the fork. *Sign in* (cloud Soniox: synced, diarized, metered minutes)
  vs *Use offline* (on-device Nemotron: free, private, no account, English-only).
- **Setup** — cloud shows the sign-in controls (`MacSignInControls`); offline
  downloads the on-device model. Offline **blocks Continue** until both FluidAudio
  models are on disk, because recording hard-fails without them.
- **Capture** — Microphone vs Microphone + System Audio (writes `opencaptions.audioSource`).
- **Permissions** — requests the microphone, and (when the choice includes system
  audio) surfaces the macOS **"Audio Recording"** prompt up front rather than
  deferring it to the first recording.
- **Ready** — recap + "Start Transcribing".

The layout is a **single centered card** (not a two-pane assistant) to stay close
to the app's minimal, native aesthetic and fit the existing window. Design
exploration lived in a clickable HTML mockup during review.

## Persistence & the gate

A per-user persistence pattern, extended for guests
(`MacAuthManager+Onboarding`):

| Key | Meaning |
|---|---|
| `hasCompletedOnboarding` (global) | Gate flag. |
| `"{owner}_hasCompletedOnboarding"` | Per-owner completion; `owner` = uid or `"local"`. |
| `opencaptions.guestMode` | Deliberate offline guest vs signed-out/expired cloud user. |
| `opencaptions.offlineMode.enabled` | Forced **on** for guests. |

**Gate** (`OpenCaptionsApp`, via `@AppStorage` so it re-renders on write):

```
if hasCompletedOnboarding && (auth.isSignedIn || guestMode) → ContentView
else                                                        → MacOnboardingView
```

- A returning, already-onboarded cloud user is whisked straight into the app: on
  sign-in, `saveUserID → mirrorOnboardingState` copies the per-uid flag into the
  global flag (so a *different* new user on a shared Mac still onboards) and clears
  `guestMode`.
- A signed-out / token-expired cloud user (onboarded but neither signed in nor a
  guest) falls back to onboarding to re-authenticate.
- The offline path finishes with **no observable auth change**, so `@AppStorage`
  on the gate flags — not `auth` — is what flips the UI.

## Offline guest mode

The app previously hard-required sign-in. A guest never signs in, so `userID`
stays nil. Making that safe required three decisions:

1. **Local owner sentinel.** Guest sessions save under `MacAuthManager.guestOwnerId`
   = `"local"`, not `nil`. `nil`-owner rows are (a) invisible to the uid-scoped
   list and (b) claimed by the first account to ever sign in on the Mac
   (`SessionOwnerBackfill`, which matches `userId == nil`). A stable sentinel makes
   read == write **and** keeps guest rows out of that backfill. The effective owner
   (`MacAuthManager.ownerId` = `userID ?? "local"`) is threaded through the history
   query, the save path, and the detail-view ownership guard.

2. **Force-lock offline for guests.** The metered-cloud balance gate *fails open*
   when RevenueCat isn't configured (which it never is for a guest) and the Soniox
   key is app-embedded — so a guest on the cloud path would get free unlimited
   transcription. `completeOnboarding(guest:)` sets `offlineMode = true` and the
   Settings toggle is `.disabled` for guests, so the cloud engine is never selected
   (`isOffline ? .nemotron : .soniox`) and the paywall is never reachable.

3. **Firestore stays nil for guests.** `FirestoreSyncService.currentUid()` uses
   `userID` (nil for a guest), *not* the `"local"` sentinel — so every share/sync
   write no-ops and no auth-required rule is ever hit. Guest sessions are local-only.

### Guest → account upgrade

Settings → Account offers a guest "Sign In to Sync" sheet (`MacSignInControls`).
On success it calls `completeOnboarding(guest: false)` (so the gate keeps them in
the app despite the fresh account's per-uid flag being unset) and migrates their
`"local"` sessions to the uid via `SessionOwnerBackfill.claimGuestSessions`. That
migration is **only** triggered by this explicit action — never automatically at
launch — so it can't silently absorb a shared Mac's guest history.

## System-audio permission priming

A Core Audio process tap has **no preflight/request API and no status API** — the
OS prompts on the first `AudioDeviceStart` and never reports the result back. So
the Permissions step can only *trigger* the "Audio Recording" prompt, by briefly
starting and stopping a probe tap (`SystemAudioTapCaptureService.primeAudioRecordingPermission`).
It surfaces the prompt during onboarding (per the user's request) but shows a
neutral "Requested" state — it cannot confirm the grant. Recording still starts
optimistically and shows its own recovery UI if denied.

## Notable changes

- `SignInView` (the old standalone pre-auth screen) was removed; its controls moved
  into the reusable `MacSignInControls`.
- The record hotkey now allows a guest (`isSignedIn || isGuest`).
- Sidebar footer + Settings Account/Usage/Recording panes are guest-aware.

## Deferred

- Account deletion / password reset / email verification (already deferred).
- Localization — macOS UI strings (including onboarding) remain hardcoded English.
- Migrating a guest's *audio files* (not just session rows) on upgrade, if any exist.
