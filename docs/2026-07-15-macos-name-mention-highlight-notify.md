# macOS: Mark & notify when the user's name is mentioned; bias the engine dictionary

**Date:** 2026-07-15
**Target:** OpenCaptions (standalone macOS app)

## Summary

Three related changes so a user knows — and is told — when their name is spoken
during a live transcription, and so Soniox transcribes that name correctly in the
first place:

1. **Mark** — the signed-in user's name is highlighted in the transcript as a bold
   `@Name`.
2. **Notify** — a *focus-gated* alert fires when the name is spoken.
3. **Dictionary** — the name is appended to the Soniox context `terms` so
   recognition is biased toward it.

This builds on the existing `HighlightedMessageText` (which did question
highlighting only), adding the name-mention half.

## 1. Mark — bold `@Name` highlight

- `HighlightedMessageText` gains a `userName: String?` init parameter and a
  `.nameHighlight` segment. Detection is `NameMentionMatcher` — a case-insensitive
  `\bname\b` whole-word regex (the name is regex-escaped; a blank name matches
  nothing).
- Rendering: a matched name is prefixed with `@` and bolded via
  `inlinePresentationIntent = .stronglyEmphasized`. **Why bold + `@` and not a
  color:** decided with the product owner. `Color.DS` had no red/destructive
  token, and `@Name` reads like a mention while
  bolding *relative to* the inherited transcript font — so the app-wide/transcript
  font-size multipliers are preserved (an explicit bold `.font` would override the
  size). No new design token was needed.
- Overlap: where a name range sits inside a question sentence, **name wins** (the
  chunk renders bold `@Name`, not tinted).
- Cache: the segment cache key became `"message|userName"` so two users on a shared
  Mac never read each other's parsed segments; a `regexCache` compiles each name
  once per session.
- Wired into all four transcript surfaces: live committed bubbles + live partial
  (`MacLiveTranscriptionView`), saved-session rows (`MacSessionDetailView+Playback`),
  and the floating captions overlay's committed + partial lines
  (`CaptionsOverlayView`). Name source: `MacAuthManager.shared.userName` — in-scope
  as `auth` in the live view; read from the shared singleton in the captions overlay
  (hosted in an `NSHostingView` with no environment) and in the detail-playback
  extension (its base file is at the 250-line limit).

## 2. Notify — focus-gated hybrid (net-new)

Decided with the product owner among {in-app cue only, OS notification only,
focus-gated hybrid, defer}: **focus-gated hybrid**.

- `MacNameMentionNotifier` (`@MainActor` singleton) is called from
  `flushSentence()` — the finalized-sentence commit point — with the trimmed
  sentence and the session's `serviceGeneration`.
- **Finalized lines only** (never the noisy ~5 fps partial) and **debounced** (≥5 s
  between alerts) so a name repeated in quick succession doesn't spam. The debounce
  clock resets per session (generation change).
- **Focus gate:** `NSApp.isActive` → show the transient HUD badge (the same overlay
  the global hotkeys use, generalized to take an icon + message); otherwise post a
  macOS local notification so the alert reaches the user in whatever app they're in.
  Highlighting already covers the "looking at the transcript" case, so the OS
  notification is the meaningful net-new value for the backgrounded case.
- **Authorization** is requested lazily and *only* when an OS notification is
  actually needed — i.e. a real mention while backgrounded — via a request-then-post
  pattern: `postLocalNotification` awaits the idempotent `requestAuthorization`
  (which resolves to the final decision, waiting for the one-time prompt) and posts
  on grant. This (a) never prompts an offline guest or a user whose name is never
  spoken, and (b) avoids a race where a settings read sees `.notDetermined` and
  silently drops the first mention. No entitlement / Info.plist usage string is
  needed for local notifications under the App Sandbox.
- The gate on `isRunning` skips the tail flush at `stop()` (which runs after
  `isRunning` is already off), so ending a recording never fires a stray alert.
- Notification body is deliberately generic ("Your name was spoken in the
  transcription.") — the sentence could be sensitive and would surface on the Lock
  Screen / Notification Center.

`NameMentionMatcher` is shared between the highlight and the notifier so what gets
*marked* and what triggers a *notification* can never drift apart.

## 3. Dictionary — bias Soniox toward the name

`MacTranscriptionViewModel.makeSonioxConfig()` took no parameters and hardcoded
`terms: ["Open Captions", "Soniox", "Apple Developer Academy"]`. It now takes
`userName: String?` and appends the trimmed name to `terms` (self-guarding — a
blank/nil name appends nothing, and `SonioxConfig.toDictionary()` omits empty
context anyway). Threaded from the sole call site in the `@MainActor start()` via
`MacAuthManager.shared.userName`. No struct change (`Context.terms` already exists).

Broadening `buildSonioxConfig` (currently 3 `general` entries + a `nil`
transliteration `text` instruction) was left as-is — out of scope, and the
config never previously injected the user's name.

## Account-settings note

The Settings → Account **Name** field gained a caption advising the user to set the
name people actually call them, because Open Captions listens for it and alerts them when
it's spoken. A short calling name works better than a full legal name for both
recognition and the mention alert.

## Deferred to a follow-up

**Capturing the name during onboarding** was raised (a good short name is what makes
this feature work) but deferred to a separate issue: it needs a new wizard step,
and the offline-guest path has no account/name at all today (guests never sign in,
so `MacAuthManager.userName` is nil for them), plus a product decision on
nickname-vs-legal-name. That is a distinct flow, not a bolt-on to this work.

## Not done / follow-ups

- Localization: macOS UI strings (including the new HUD/notification/settings copy)
  remain hardcoded English, consistent with the rest of OpenCaptions (no
  `LanguageManager` yet).
- No `UNUserNotificationCenterDelegate` for foreground banner presentation — not
  needed, since OS notifications are only posted when the app is *not* active.
