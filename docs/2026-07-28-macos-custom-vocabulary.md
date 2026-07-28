# macOS: custom vocabulary (term biasing) — a Vocabulary module, cloud paths only

**Date:** 2026-07-28 · **Scope:** Open Captions only
**Related:** `docs/2026-07-15-macos-name-mention-highlight-notify.md` (§3
"Dictionary" — the only prior decision about Soniox `context.terms`),
`docs/2026-07-04-macos-standalone-mvp.md` (the original Soniox config),
`docs/2026-07-16-macos-post-session-retranscription.md` (the async re-transcribe
path that carried the duplicate list), `docs/2026-07-10-macos-on-device-engines.md`
and `docs/2026-07-10-macos-offline-mode.md` (why offline gets nothing here),
`docs/2026-07-27-remove-feature-flags.md` (decision 3: a local Settings toggle is a
preference, not a flag)

Closes #10.

## Context

Domain-specific terms — names, product names, acronyms, jargon — got mis-heard and
the user had no way to correct that. The bias list was a **literal, hardcoded twice**:

- `ViewModel/MacTranscriptionViewModel+Engine.swift` — `["Open Captions", "Soniox",
  "Apple Developer Academy"]` plus the signed-in display name (live Soniox config)
- `Services/Retranscription/SonioxAsyncPostSessionEngine.swift` — a byte-identical
  copy, plus its own byte-identical copy of the three `context.general` pairs in
  `+Requests`

Both engines support term biasing. Neither exposed it, and the duplication meant the
two paths could silently bias differently — re-transcribing a session could apply a
different dictionary than the session itself used.

## Decisions

**1. A sidebar module, not a Settings pane.** The natural home looked like a fifth
`TabView` pane in `MacSettingsView`, but the Settings window is a fixed 480×460 and
this is a variable-length list editor. It went in as a fourth `NavSection`
destination in `ContentView` instead — the enum's own doc comment already advertised
that as a one-line change — so the editor gets the full detail column.

**2. Cloud only. Offline Mode gets nothing, deliberately.** NVIDIA's technique here
is CTC-WS context biasing, and FluidAudio does implement it — but only on
`SlidingWindowAsrManager` (Parakeet). Verified against the pinned v0.15.5 checkout:

| Path | Manager | Vocabulary hook in v0.15.5 |
|---|---|---|
| Live Offline Mode | `StreamingNemotronAsrManager` | **none** — zero matches for any biasing symbol across its whole `Streaming/` directory |
| Parakeet live (built, unwired) | `SlidingWindowAsrManager` | `configureVocabularyBoosting(vocabulary:ctcModels:config:)` |
| Post-session re-transcribe | batch `AsrManager` | **none** — `transcribe` takes only `decoderState` + `language` |

The three ways to change that were each rejected for this change:

- **Wire Parakeet as the live offline engine.** The only route that is a plain
  FluidAudio call, but it regresses live offline badly: first confirmed text moves
  from Nemotron's 560 ms to ~7 s (`chunkSeconds: 5.0` + `rightContextSeconds: 2.0`),
  sentence-bounded bubbles are lost (Parakeet bypasses `FluidAudioStreamBridge` and
  emits a whole window as one final), and its finals latch off permanently for the
  session if a window ever revises earlier text (the `hasPrefix(emittedConfirmed)`
  guard). Biasing is not worth that trade.
- **Post-hoc rescore Nemotron output** by driving `CtcKeywordSpotter` +
  `VocabularyRescorer.ctcTokenRescore` directly, as FluidAudio's own
  `CtcEarningsBenchmark` does. Genuinely feasible — the rescorer is non-async and
  the batch path already has the `tokenTimings` it needs — but it requires a **third
  model download** (`CtcModels.ctc110m`, indicatively ~100 MB), which touches 9
  hardcoded switch sites across `FluidAudioModelLoader` / `FluidAudioModelManager`
  plus both download UIs and their hardcoded "1.2 GB" copy. It also rests on an
  unverified assumption: the rescorer's word grouping is documented against TDT word
  locations only, and nothing confirms Nemotron's RNNT timings group compatibly.
- **Upstream a Nemotron hook.** Out of this project's hands.

So offline is a deferral with a known shape, not an oversight. The Vocabulary screen
says so in plain words rather than letting an Offline Mode user wonder why their
terms do nothing.

**3. Device-local. Not synced to Firestore.** `mergeUserDoc` replaces array fields
wholesale (`setData(merge: true)` deep-merges maps, not arrays), there is no
snapshot listener anywhere in the app, and no launch-time hydration — only the
Account pane's one-shot `fetchMarketingOptIn`. A synced list would therefore let a
fresh install with an empty local list overwrite the real list on first edit.
Syncing it safely needs read-before-write plumbing that does not exist yet.

**4. Built-ins stay built-in; the odd one out was migrated, not dropped.** Of the
three old hardcoded terms, `Open Captions` and `Soniox` are the app's own nouns —
always sent, not editable, so they cannot be deleted by accident. `Apple Developer
Academy` is not app identity; it is one developer's institution, and hardcoding it
for every user of an open-source app made no sense. It is **seeded into the user's
editable list on first launch**, so nothing regresses, and it can be deleted — the
seed only runs when the defaults key is absent entirely, so a deletion is permanent.

**5. Clamp, don't fail.** Soniox caps the whole `context` object at 10 000
characters, and exceeding it fails **the request**, not just the hints — live, that
is a session that connects and transcribes nothing. `VocabularyStore` clamps before
either path builds a config, so an over-long vocabulary loses its tail instead of
breaking the session, and the screen shows a budget meter that turns red before the
user gets there.

Clamp priority is most-important-first: **display name → built-ins → user terms in
editor order → background text into whatever is left.** The display name leads
because the name-mention highlight and notification match the transcript literally
(`\bname\b`), so a mis-heard name means no highlight and no alert — it is the term
least worth losing. `docs/2026-07-15-macos-name-mention-highlight-notify.md` §3
promised that term stays biased; it still does, and now it cannot be evicted by a
long user list.

**6. Measure the serialized JSON, in scalars.** `Context.characterCount` serializes
the context and counts that, so the braces, quotes, and escapes that go on the wire
are included — the measure over-states the raw content by that envelope, putting
clamping on the safe side of the cap.

It counts **unicode scalars, not `String.count`**. Swift's `count` is grapheme
clusters, and one grapheme can be many scalars (a decomposed diacritic, an emoji ZWJ
sequence), so a grapheme count could sit under 10 000 while any larger server-side
unit was well over it. Soniox's cap isn't documented as grapheme-based, so the code
counts the larger unit. This costs ordinary vocabularies nothing: for ASCII and for
all three language hints this app sends (id/en/ar) in normal form, scalars and
graphemes are identical. Bytes would be more conservative still, but would penalize
Arabic and Indonesian text by ~2× against a cap that may well be character-based.

**7. Also exposed `context.text`, not `context.general`.** The freeform background
note (an agenda, prior notes, a topic) was always `nil` and is high-value for
lectures and meetings, so it is now a field sharing the same budget. The
`general` key/value pairs stay fixed — they describe the app and the material, not
anything a user maintains — but they moved to a single
`SonioxConfig.Context.appGeneralEntries`, killing the second duplicated literal.

**8. Surfaced Soniox's own error.** An oversized context is exactly the failure
this change had to guard, so it was worth checking what the user would have seen:
nothing useful. A Soniox `error_code` frame was printed and dropped, and because
Soniox then closes the socket, the user got the generic "Connection lost." A
rejected config now fails the session with Soniox's own message. This is safe
against double-failure: `failSession` is guarded on `isRunning || isPaused`, so the
generic failure that follows the socket close is a no-op and the specific message is
what stays on screen. Serializing an unencodable config now throws from
`connectAndStart()` instead of leaving the socket open and streaming audio Soniox
never configured; the send itself stays fire-and-forget, because awaiting it would
block on the handshake and bring back the startup delay that was deliberately
removed.

## Editing semantics

Edits live-commit to the store (no Save button — matching how the Settings toggles
behave), but are read **once at session start**: the config is the socket's first
frame and is never resent. Hence the "Applies to your next session" note, the same
convention the other next-session preferences use.

Blank rows are an editor affordance, not data: they are legal in memory so a fresh
row can be typed into, excluded from what is persisted, dropped when building the
context, and pruned on load so the editor never opens onto empty rows.

Duplicates are folded case-insensitively (biasing is not case-sensitive, and sending
both spellings just spends budget). Because a folded duplicate would otherwise look
like a term that failed to save, the row flags it instead.

## What changed, file by file

**New**

- `Model/VocabularyTerm.swift` — the value type. A struct rather than a bare
  `String` because `id` gives an editor row a stable identity while its text is being
  typed, and per-term aliases/weights can be added later as optional properties
  without invalidating persisted JSON.
- `Utility/Vocabulary/VocabularyStore.swift` — `@Observable @MainActor` singleton;
  terms, background note, editing methods, duplicate detection. Loads in `init`
  rather than behind a `start()`: a session can be started from the **menu bar** with
  the main window never opened, so anything hung off the window's launch task could
  be skipped, and a vocabulary that silently did not load is invisible.
- `Utility/Vocabulary/VocabularyStore+Persistence.swift` — JSON `Data` under one key,
  following `HotKeyManager`'s precedent (`try?`-silent, code-level default rather
  than a `register(defaults:)` entry, since a blob has no sensible registered
  default). The key's absence is what marks a first launch.
- `Utility/Vocabulary/VocabularyStore+SonioxContext.swift` — the single place the
  wire list is assembled, plus the clamping. Both clamps binary-search rather than
  append-and-measure: serialized length is monotonic in the prefix, so it costs
  O(log n) measurements, and an over-budget list can hold thousands of short terms.
- `Views/Vocabulary/VocabularyScreen.swift`, `Views/Vocabulary/VocabularyTermRow.swift`
  — the editor. The row takes the `FocusState` binding as a parameter because
  `.focused` has to sit on the `TextField` itself.
- `docs/2026-07-28-macos-custom-vocabulary.md` — this note.

**Changed**

- `Model/SonioxConfig.swift` — `Context` gains `toDictionary()`, `characterCount`,
  `fitsCharacterLimit`, `characterLimit`, and `appGeneralEntries`; `SonioxConfig`'s
  own serializer now delegates to it. `Context`/`GeneralEntry` are `Sendable` so the
  async engine can hold one.
- `ViewModel/MacTranscriptionViewModel+Engine.swift` — `makeSonioxConfig` reads the
  store instead of a literal (and is now explicitly `@MainActor`: the class isolates
  members individually, not at type level, so a static needs saying). `onError` now
  fails the session on a Soniox provider error.
- `Services/Retranscription/SonioxAsyncPostSessionEngine.swift` + `+Requests.swift` —
  takes an injected `SonioxConfig.Context` instead of a `userName` it built a list
  from, and serializes it with the shared `toDictionary()`. `context` is now omitted
  when empty rather than always sent.
- `Services/Retranscription/PostSessionRetranscriptionFactory.swift` — resolves the
  context (hence `@MainActor`; its only caller, `PostSessionRetranscriber.run`,
  already was).
- `Services/Transcription/OnlineTranscriberService.swift` + `+Messages.swift` — throw
  on unserializable config, report send failure, report `error_code` frames.
- `Model/TranscriptionError.swift` — new `.provider(code:message:)` case.
- `ContentView.swift` — `NavSection.vocabulary` + its detail branch.
- `LiveSessionStore.swift` — `vocabularyTermsKey`, `vocabularyBackgroundTextKey`.

## Consequences

- Re-transcription can no longer bias differently than the live session did: both
  read one builder.
- `SonioxAsyncPostSessionEngine.init(userName:)` is gone. Anything constructing it
  directly must go through `PostSessionRetranscriptionFactory` (or resolve a context
  itself on the main actor).
- Two more `opencaptions.*` keys, neither in `register(defaults:)` — see decision 4
  for why absence is load-bearing. A user who resets defaults loses their vocabulary
  and gets the seed back.
- Offline Mode users see the Vocabulary module and can fill it in; it affects their
  cloud re-transcriptions but not their live offline sessions. The screen says this.

## Verification

Built in Xcode (Debug, macOS, `OpenCaptions` scheme): **BUILD SUCCEEDED**, no new
warnings in any touched file. There are no unit tests in this target.

## Known deferrals

- **Offline biasing** — see decision 2. The post-hoc `CtcKeywordSpotter` +
  `VocabularyRescorer` route is the viable one; it needs a CTC model download and a
  spike confirming Nemotron's token timings group compatibly with the rescorer.
- **Per-term aliases and weights** — both Soniox and FluidAudio accept them;
  `VocabularyTerm` is shaped to grow them without breaking persisted JSON.
- **Cross-device sync** — see decision 3; needs read-before-write plumbing first.
- **Background note truncation is by character, not word.** The note is a
  recognition hint and is never displayed, so a clipped final word costs nothing.
