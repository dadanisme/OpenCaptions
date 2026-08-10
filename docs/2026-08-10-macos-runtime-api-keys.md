# macOS: runtime-editable Soniox/OpenRouter API keys

**Date:** 2026-08-10 · **Scope:** Open Captions only · **Closes:** #37
**Related:** `docs/2026-08-10-remove-accounts-and-firestore.md` (removed the
`keychain-access-groups` entitlement this re-adds, for an unrelated reason — Firebase
Auth's keychain persistence, not this), `docs/2026-08-04-macos-openrouter-summaries.md`
(the OpenRouter transport `apiKey()` feeds), #32 (Developer ID / DMG distribution — the
actual forcing function, see Context)

## Context

Both API keys were build-time only: `Config.xcconfig` → `OpenCaptions-Info.plist` →
`Bundle.main.infoDictionary`. The only way to change either was to edit the xcconfig and
rebuild in Xcode. That's fine for a developer compiling their own copy, but #32 (Developer
ID + notarized DMG distribution) means the app will eventually ship as a binary most
users never compile — those users have no way to plug in their own Soniox/OpenRouter keys
at all once that lands.

`SonioxSecrets.sonioxAPIKey` also `fatalError`'d on a missing key — a launch-time crash
that made sense while the key was a fixed, developer-controlled build input, but not once
a normal user can be missing one temporarily.

## Decision

**Keychain, not UserDefaults**, for the two runtime values. This was a genuine trade-off
worth surfacing rather than assuming: UserDefaults would have matched the existing
`opencaptions.*` convention with zero new infrastructure, while Keychain is encrypted at
rest but means re-adding the `keychain-access-groups` entitlement that `10f221e` (#36)
had just deleted hours earlier, plus writing an entirely new `Security`-framework wrapper
with no precedent in this codebase. Asked and decided explicitly in favor of Keychain —
these are real secrets (a leaked key spends someone's Soniox/OpenRouter balance), and the
"local-only, minimal surface" direction #36 pushed doesn't mean "avoid secure storage,"
just "avoid a backend."

**A runtime key always wins over the build-time one**, never the reverse — so an existing
dev build with `Config.xcconfig` filled in keeps working unchanged with nothing in
Settings. Both `SonioxSecrets.sonioxAPIKey` and `SummaryService+OpenRouter.apiKey()` check
`APIKeyStore` first and only fall through to `Bundle.main.infoDictionary` when it's unset.

**`SonioxSecrets.sonioxAPIKey`'s `fatalError` is gone.** It's now `String?` — a missing
key is a normal, recoverable runtime state, not a launch-time misconfiguration. That
pushed a design question up a level: the live path builds a `SonioxConfig` far from where
the key is actually needed (`OnlineTranscriberService.connectAndStart()`, inside the
JSON the WebSocket config frame is built from), and a missing key there wouldn't fail
`JSONSerialization` — it would open a socket, send a config with an empty `api_key`, and
only fail once Soniox's server rejects it. That's a bad UX (a live socket, a wait, then a
server-worded error) for something checkable instantly. So the check moved to
`MacTranscriptionViewModel.start()`, right next to the existing "on-device model isn't
downloaded yet" pre-flight guard, on the same reasoning: nothing (no audio, no socket) is
open yet at that point, so there's nothing to tear down on failure — a plain
`isRunning = false; errorMessage = …; return`, not `failSession(message:)` (which exists
specifically to abort something already live). The guard is conditioned on
`kind == .soniox`, since `makeSonioxConfig` runs unconditionally regardless of engine
kind and on-device engines don't need this key at all.

The async post-session engine (`SonioxAsyncPostSessionEngine.transcribe`) already had a
well-typed error enum, `PostSessionEngineError` — a missing key there throws the new
`.missingAPIKey` case rather than crashing, following the same shape as the existing
`.modelNotDownloaded` case.

**`SUPPORT_EMAIL` stays build-time only**, per the issue — it's config, not a secret.

## What's new

- **`Utility/APIKeyStore.swift`** — a small `enum` wrapping `SecItemAdd` /
  `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete` for two generic-password
  items (`Key.soniox`, `Key.openRouter`), keyed by a private `kSecAttrService` +
  `kSecAttrAccount`. `write(_:value:)` deletes the item instead of storing an empty
  string — an empty Settings field means "use the build-time key, if any," not "use an
  empty key." No explicit `kSecAttrAccessGroup` in the queries; the app's own
  `keychain-access-groups` entry (below) supplies the default.
- **`OpenCaptions.entitlements`** — `keychain-access-groups` re-added
  (`$(AppIdentifierPrefix)com.muhammadramdan.OpenCaptions`), the same value Firebase Auth
  used before #36. Required under App Sandbox for `SecItemAdd`/`SecItemCopyMatching` to
  work at all for the app's own items — without it, calls fail with
  `errSecMissingEntitlement` (-34018), the exact failure this project already hit once.
- **`Views/Settings/MacAPIKeysSettingsView.swift`** — the 4th Settings tab (General /
  Shortcuts / Support / **API Keys**). Two sections, one per key: a masked `SecureField`
  (the first in this codebase) with an eye-icon reveal toggle and a copy button
  (`doc.on.clipboard`, matching `MacSessionDetailView.copySessionMarkdown()`'s existing
  icon). No local draft state — the field is a `Binding` that reads/writes `APIKeyStore`
  directly, so it always reflects what's actually stored.
- **`PostSessionEngineError.missingAPIKey`** — "Add a Soniox API key in Settings → API
  Keys, then try again."

## Files

- **New** `Utility/APIKeyStore.swift`, `Views/Settings/MacAPIKeysSettingsView.swift`.
- `OpenCaptions.entitlements` — `keychain-access-groups` re-added.
- `Utility/Sonioxsecrets.swift` — `sonioxAPIKey` is now `String?`, Keychain-first,
  `fatalError` removed.
- `Model/SonioxConfig.swift` — `toDictionary()`'s `api_key` unwraps to `""` on nil (never
  hit for a live Soniox session; `start()` guards first).
- `ViewModel/MacTranscriptionViewModel.swift` — `start()` gains the missing-key pre-flight
  guard, conditioned on `kind == .soniox`.
- `Services/Retranscription/SonioxAsyncPostSessionEngine.swift` — guards the key instead
  of force-reading it.
- `Services/Retranscription/PostSessionTranscriptionEngine.swift` —
  `PostSessionEngineError.missingAPIKey` added.
- `Services/SummaryService+OpenRouter.swift` — `apiKey()` checks `APIKeyStore` first.
- `Services/SummaryService.swift` — `.unauthorized`'s copy no longer names
  `Config.xcconfig` specifically, since the key can now be wrong at runtime too.
- `Views/Settings/MacSettingsView.swift` — 4th `Tab` case + switch branch + Picker tag.
- `CLAUDE.md` — Credentials, App shell & windowing, and Coding Standards (`fatalError`
  count) sections updated.

## Unchanged on purpose

`VocabularyStore`, `SonioxConfig.Context`, and every other Soniox/OpenRouter consumer are
untouched — this only changes where the two API key *strings* come from, not anything
downstream of them. `SUMMARIZE_URL`/`SUPPORT_EMAIL` and the rest of `Config.xcconfig`'s
shape are unaffected.

## Follow-ups not taken

- **No automatic migration** of an existing `Config.xcconfig` value into the Keychain.
  Not needed — the build-time value keeps working as the fallback for as long as Settings
  is left blank, so a current dev build needs no action.
- **No "Test Connection" button** in the new Settings tab. The existing pattern for a
  wrong/rejected key is already to surface the failure where it actually happens (session
  start, or a summary's `.unauthorized`) — out of scope to add a separate validation path.
- **No key rotation reminder / expiry UI.** Neither Soniox nor OpenRouter keys expire on
  a schedule this app could track.
- **The stale project-level signing team (`YN8NVQ69WY`, see CLAUDE.md's Build & Run) is
  left as-is.** `$(AppIdentifierPrefix)` in the re-added `keychain-access-groups` entry
  resolves per whichever team actually signs the build; if that ever differs between two
  builds a user runs, a previously-saved Keychain item becomes unreadable under the new
  prefix and looks like the key silently vanished. The target's real team (`C4SQMCY5WT`)
  is what applies today, so this isn't a live bug — fixing the stale project-level team
  itself is unrelated cleanup, not part of this issue.

## Verification

Manual, in Xcode (there are no unit tests in this project):

1. Settings → API Keys with both fields blank, `Config.xcconfig` filled in → sessions and
   summaries work exactly as before (build-time fallback).
2. Enter a Soniox key in Settings, blank `Config.xcconfig`'s → a session starts using the
   Settings key.
3. Blank both Soniox sources → Start shows "Add a Soniox API key in Settings → API Keys
   to start a session." instead of crashing; no audio/socket resources are left open.
4. Blank both OpenRouter sources → Summarize shows "Unauthorized — add or check your
   OpenRouter API key in Settings → API Keys."
5. Re-transcription (Soniox async) with no key configured → surfaces
   `PostSessionEngineError.missingAPIKey`'s copy instead of crashing.
6. Reveal/hide toggle and Copy button both work; relaunch the app → entered keys persist
   (Keychain survives relaunch, unlike in-memory state).
