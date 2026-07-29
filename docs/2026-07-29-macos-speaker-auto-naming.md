# macOS: auto-name diarized speakers from the summarization pass

**Date:** 2026-07-29 · **Scope:** Open Captions only · **Closes:** #14
**Related:** `docs/2026-07-24-macos-native-gemini-summary.md` (the schema + prompt this
extends — two of its decisions are amended there), `docs/2026-07-16-macos-post-session-retranscription.md`
(a second, headless caller), `docs/2026-07-06-macos-firestore-share.md` (the mirrored
`speakers` map), `docs/2026-07-10-macos-offline-mode.md` (why offline sessions opt out)
**Status:** implemented. The project has no test target, so the threshold rules, the
lenient decode, and the transcript format were verified by an out-of-tree simulation
compiled against the real sources (42 assertions — see *Verification* below); the rest
is manual.

## Context

Every diarized session used to land with generic labels — "Speaker 1", "Speaker 2" — and
the only way to fix them was by hand through the Edit Speakers sheet. But the names are
usually sitting right there in the transcript ("Hi, I'm Ramdan", "What do you think,
Sam?"), and the summarization pass already ships the entire speaker-labelled transcript
to Gemini. We were paying for a full read of the conversation and throwing the identity
signal away.

So the summary call now also predicts who each speaker is, and the confident predictions
are applied automatically. It costs one extra optional field in a request we were already
making.

## Decisions

1. **The transcript carries the speaker id, always — even once the speaker has a name.**
   This is the load-bearing change. `ConversationFormatter.buildTranscript` used to print
   `line.speakerName` and drop the numeric id the moment a speaker had a name, so on a
   re-run the model saw `Ramdan：…` with no id to map a prediction back to. The label is
   now `Speaker {id}`, with any assigned name **appended in parentheses** rather than
   substituted:

   ```
   Session title：Weekly sync
   Session Date：26 Jul 2026 at 00.20

   Diarized speakers in this session：
   - Speaker 1
   - Speaker 2 (Alice)
   - Speaker 3 (Simon/Sam)

   Here is the complete dialogue (with timestamps, speaker ids, and any names already assigned)：

   [0:00:00] Speaker 1：Hi everyone, I'm Dana and I'll run the agenda today.
   [0:00:07] Speaker 2 (Alice)：Thanks Dana. Quick update from my side.
   [0:00:15] Speaker 3 (Simon/Sam)：I can take the deploy.
   [0:00:21] Speaker 1：Great, Simon — ship it Friday.
   [0:00:31] and that wraps the agenda.
   ```

   Additive, not substitutive: a named speaker still exposes its id, which is what makes a
   re-run resolvable. In the common case — nobody named yet — **the dialogue lines
   themselves** are byte-identical to the old format and cost zero extra tokens; only the
   roster and the reworded intro sentence are new. Rejected: `#2 Alice：` (a bare sigil
   diverges from the "Speaker N" vocabulary the app, the prompt, and the UI all share) and
   `Alice (#2)：` (degenerates to the absurd `Speaker 2 (#2)` for a default label).

   **This is safe to change only because `buildTranscript` has exactly one caller**,
   `SummaryService.summarize(session:language:)`. It is the model-facing format, not a
   user-facing one — the transcript the user copies or exports goes through
   `MarkdownFormatter`, which is untouched. Anyone adding a second caller should know
   they are getting a prompt payload.

2. **A speaker roster precedes the dialogue, bounding the id space.** Each diarized id
   once, ascending, rendered by the same helper as the body so the two can never disagree
   and hand the model contradictory input. Without it the model can predict a name for an
   id that isn't in the session. The block is **omitted entirely** when no line has
   `speakerId > 0`, so a non-diarized transcript keeps the pre-#14 shape exactly — same
   single blank line before the dialogue intro, no roster, no labels. (Its intro *sentence*
   was reworded for every session, so it is not byte-for-byte identical; the layout is.)

   Note the roster keys off `speakerId > 0`, not off "is anyone named" — a diarized session
   whose speakers are all still generic gets a roster of generic labels. That is deliberate:
   bounding the id space is exactly what the first summary pass needs.

3. **`SpeakerLabel` is now the single definition of "is this label still generic?"**
   `TranscriptionLine.speakerName` has no sentinel for "unnamed", and this is a real trap:
   a **live** session stores the literal string `"Speaker 3"` (`TranscriberModel.appendOrAdd`),
   and so does re-transcription for a diarized line — `PostSessionSegmentBuilder` writes
   `"Speaker \(id)"` for `id > 0` and `""` only for a non-diarized one. So `""` is the rare
   case, not the common one, and both spellings mean the same thing: unnamed.
   The existing formatters tested only `speakerName.isEmpty`, which is therefore dead
   for every live session — reusing it here would have emitted `Speaker 3 (Speaker 3)：` on
   every live transcript. `SpeakerLabel.isDefault(_:id:)` / `.display(_:id:)` now back both
   `ConversationFormatter` and `MarkdownFormatter` (identical output for the latter — a
   dedup, not a behavior change).

4. **The persistence path moved out of the view layer.** `saveSpeakerNames` did exactly the
   right thing already — write the name onto every line with that id, save the context,
   mirror to the shared Firestore doc via `updateSpeakerNames` when `cloudSessionId` is set
   — but it lived in `MacSessionDetailView+SpeakerEditing`, so the summary path couldn't
   reach it without routing through a view. It is now `SpeakerRenamer.apply(_:to:context:)`
   in `Services/Speakers/`, and the detail view's two rename sheets call it directly.
   The `cloudSessionId` guard stays **inside** `SpeakerRenamer` so no caller has to know
   that an unshared session is a normal no-op rather than a failure.

   Named `SpeakerRenamer`, not `SpeakerNameService`: in this repo the `…Service` suffix is
   for stateful classes (`FirestoreSyncService`, `SummaryService`), while stateless helpers
   are agent-noun enums (`SessionLinkSharer`, `PostSessionRetranscriber`).

5. **Applied silently — no confirmation, no undo banner.** Edit Speakers remains the
   correction path. It runs on every summary generation, including re-runs and the
   post-session re-transcription path.

### Thresholds

Both live as `private static let` on `SpeakerNameResolver` — the one place that decides
anything — with `SpeakerNameResolver.resolve` turning predictions into the `[id: name]`
map `SpeakerRenamer` persists. Deliberately **not** added to `TranscriptionConstants`:
that enum is the live STT pipeline's namespace (memory window, bubble grouping,
connection health), and a summary-pass confidence pair has no business there.

| Case | Result |
|---|---|
| Exactly one candidate above **0.85** | Rename to that name — `Speaker 1` → `Ramdan` |
| Otherwise: every candidate above **0.35** | Rename to the slash-joined list — `Speaker 2` → `Simon/Sam` |
| Nothing above **0.35** | Leave the generic label untouched |

- **0.85 is high on purpose.** A confidently wrong name is worse than an honest
  "Speaker 2", and there is no undo. (Unrelated to the 0.85 on-device confirmation
  threshold in `docs/2026-07-10-macos-on-device-engines.md` — same numeral, different
  tunable.)
- **0.35 is a floor, not a decision.** Between the two, the model has narrowed the
  identity without settling it, and showing the user that narrowing beats hiding it.
- **"Exactly one above 0.85" is what keeps both thresholds load-bearing.** The issue's
  wording was ambiguous here. A clear winner wins outright *even when a weaker candidate
  also clears the floor* (`Alice 0.9` + `Alicia 0.4` → `Alice`, not `Alice/Alicia`), while
  two equally confident contradictory names surface as `Simon/Sam` rather than being
  silently picked between. Read the other way, the 0.85 row would have been pure dead
  weight — every case it covers would already fall out of the 0.35 row.
- Comparisons are **strictly greater than**, matching the issue's `> 85%` / `> 35%`.
- The joined list is ordered by descending confidence so it reads most-likely-first, and
  case-insensitive duplicates collapse onto their best occurrence — the model can list a
  name twice, and "Sam/Sam" is not a speaker name.
- **The thresholds are never stated to the model.** It reports calibrated confidence; the
  app decides. Leaking them into the prompt would just invite the model to game the
  number it is being scored on.

### The prompt

A new `SPEAKER IDENTIFICATION` section in `systemInstruction`, placed after
`INPUT PROCESSING` (it is a how-to-read-the-input rule) and before `FORMATTING RULES`.
Three bullets carry most of the weight:

- **Two kinds of evidence only** — a self-introduction, or another speaker addressing them
  directly. This is the whole precision guarantee.
- **Never from a role, job title, topic, session title, or a third party who is only
  talked about.** Closes the obvious failure mode: naming a speaker after someone merely
  discussed.
- **The parenthetical is a hint, never evidence.** Without this, a wrong guess from an
  earlier pass gets echoed back with high confidence and frozen in place.

Plus one exception clause, because `LANGUAGE` at the top says "write the entire output in
{language}": speaker names are never translated or transliterated. It is scoped to the
`speakers` array so it doesn't contradict `INPUT PROCESSING`'s "standardize names, places,
and technical terms", which governs the summary prose.

### Failure is silent by contract

**A malformed or absent `speakers` field must never cost the user their summary** — and
getting this right needed more than an optional.

`decodeSummary` runs a plain `JSONDecoder` over the response, and that decode is
all-or-nothing: declared as `[SpeakerIdentification]?`, the synthesized decoder would call
`decodeIfPresent` on the array, which **throws** on any type mismatch and takes `title`,
`summary`, and `keyPoints` down with it. The user would lose the entire summary to
"The summary response was malformed" because the model spelled one `speakerId` as a
string.

So the field is typed `SpeakerPredictions?`, a wrapper whose `init(from:)` **cannot
throw**: `try?` absorbs "not an array at all", and a per-element `Lenient` wrapper absorbs
a bad element while keeping its well-formed siblings. Every malformation degrades to "the
model named nobody". The `identifiedSpeakers` accessor flattens it so callers never see
the wrapper.

Downstream is failure-tolerant too: `resolve` drops anything unusable rather than
reporting, `apply` returns `[:]` when nothing changed, and a save error is logged, not
thrown. This matters because `PostSessionRetranscriber` calls `generateSummary` on a
throwaway `SummaryViewModel` whose `errorMessage` nobody ever reads.

### Non-diarized speakers are skipped, not renamed

`resolve` drops any `speakerId <= 0` before building the edit map, and `SpeakerRenamer`
drops them again on the way in. `-1` means the session wasn't diarized at all. `0` is the
subtler one: `ConversationFormatter` used to test `== -1` while `MarkdownFormatter` and
every view test `> 0`, so a stray `0` off the wire was offered to the model as a nameable
"Speaker 0" that the speaker editor could never surface — a rename that would reach
SwiftData and be invisible in the UI. The formatter's guard is now `<= 0` to match
everything else.

## Known deferrals

- **A re-run can overwrite a manual rename.** Running on every summary means a user who
  fixed "Simon/Sam" to "Sam" by hand can have it re-predicted on the next summary, and
  there is no undo. Partly self-limiting — the transcript feeds the corrected name back
  to the model, which will likely keep it — and partly mitigated by the "hint only, never
  evidence" bullet. Shipped unguarded per #14, deliberately, to be watched in real use.
  **The fix, if it bites:** skip ids whose current `speakerName` is not still generic, i.e.
  filter the edit map through `SpeakerLabel.isDefault` before calling `SpeakerRenamer`.
  That helper exists and is already correct about the `"Speaker N"`-vs-`""` trap, so the
  change is a one-line predicate in `SummaryViewModel`. The rename sheets must keep their
  unconditional overwrite — an explicit user edit is always authoritative — so it belongs
  at the summary call site, not inside `SpeakerRenamer`. Residual even then: a user who
  literally types "Speaker 2" as a name is indistinguishable from a generic label. The
  airtight version is an optional `isSpeakerNameUserEdited` flag on `TranscriptionLine`
  (optional ⇒ SwiftData lightweight migration), set only from the sheet paths.
- **Cloud only.** Offline Mode skips summary generation upstream, so offline sessions get
  no automatic naming — and offline re-transcription flattens every line to `speakerId -1`
  anyway. An offline user never sees this feature and may read that as a bug.
- **Ids are not stable across a re-transcription.** Each pass re-diarizes and rebuilds
  every line, so "Speaker 2 = Sam" from a previous pass is meaningless afterward. Names are
  therefore *re-derived* on the new transcript, never carried across. Any future attempt to
  carry them would be unsound with the current model.
- **The joined list is uncapped.** Five candidates above 0.35 would produce "A/B/C/D/E".
  The prompt discourages it and the case hasn't been seen; capping was left out rather than
  guessed at.
- **No live-view refresh.** A rename written to SwiftData does not update
  `MacTranscriptionViewModel`'s in-memory lines, so a just-ended session whose live view is
  still alive can briefly disagree. Pre-existing behavior of the manual editor, inherited
  as-is — the fix is not to have a saved-session helper reach into session-scoped live
  state.

## Files

**New**
- `OpenCaptions/Services/Speakers/SpeakerIdentification.swift` — the response DTO plus
  `SpeakerPredictions`, the non-throwing decode wrapper.
- `OpenCaptions/Services/Speakers/SpeakerNameResolver.swift` — the two thresholds and the
  candidates → `[id: name]` reduction. The only file that decides anything.
- `OpenCaptions/Services/Speakers/SpeakerRenamer.swift` — the single write path: lines,
  `context.save()`, Firestore mirror.
- `OpenCaptions/Services/SummaryService+Schema.swift` — `responseSchema`, extended with
  `speakers` and moved out of `+Gemini`: adding the sub-schema in place took that file from
  214 to 247 lines, close enough to the ~250 limit that the split was due anyway. `+Gemini`
  is 199 lines now.
- `OpenCaptions/Utility/Formatting/SpeakerLabel.swift` — the generic-vs-named rule, and the
  one place the `"Speaker N"` wording is spelled out.

**Edited**
- `OpenCaptions/Utility/Formatting/ConversationFormatter.swift` — id-carrying labels,
  the roster block, `<= 0` guard.
- `OpenCaptions/Utility/Formatting/MarkdownFormatter.swift` — routed through
  `SpeakerLabel.display` (identical output).
- `OpenCaptions/Services/SummaryService.swift` — `speakers` + `identifiedSpeakers` on
  `SummaryAPIResponse`.
- `OpenCaptions/Services/SummaryService+Gemini.swift` — schema extracted out.
- `OpenCaptions/Services/SummaryService+Prompt.swift` — the `SPEAKER IDENTIFICATION`
  section.
- `OpenCaptions/ViewModel/SummaryViewModel.swift` — the one call site, right after the
  summary save.
- `OpenCaptions/Views/SessionDetail/MacSessionDetailView.swift` — two sheets now call
  `SpeakerRenamer` directly.
- `OpenCaptions/Views/SessionDetail/MacSessionDetailView+SpeakerEditing.swift` —
  `saveSpeakerNames` removed; only `editableSpeakers` + `SpeakerRenameTarget` remain.

## Verification

There is no test target. The pure logic was checked by an out-of-tree simulation compiled
with `swiftc` against the **real** `SpeakerLabel`, `ConversationFormatter`,
`SpeakerIdentification`, and `SpeakerNameResolver` sources (plus a text-extracted copy of
the `SummaryAPIResponse` declaration and stub `TranscriptionSession`/`TranscriptionLine`
models) — 42 assertions, all passing, covering: each threshold row and both boundaries;
`-1`/`0` skipped however confident; empty, missing, blank-name, duplicate-name and NaN
candidates; absent / `null` / wrong-type / malformed-element `speakers` all leaving the
summary intact; a genuinely broken summary still failing; and every transcript branch
including the non-diarized layout (no roster, original blank-line spacing). The simulation
is scratch, not committed.

Manual, in Xcode, with a real `GEMINI_API_KEY`:

1. Record a diarized session where someone self-introduces → after the summary lands, the
   transcript shows the real name on every line of that speaker, not just the first.
2. A session where two names contend for one speaker → the label reads `Simon/Sam`.
3. A session where nobody is named → labels stay `Speaker N`; no spurious rename.
4. A non-diarized session (Offline Mode / Parakeet) → summary generates as before, no
   rename attempted, and the transcript sent to Gemini has no roster block.
5. Share a session, then re-summarize → the web view's speaker names update too
   (`speakers.{id}.name` patched).
6. Re-summarize an unshared session → renames land in SwiftData, nothing logged as a
   Firestore failure.
7. Re-transcribe a session (`PostSessionRetranscriber`) → the fresh generic labels get
   auto-named by the regenerated summary.
8. Open Edit Speakers and rename by hand → still works, still mirrors, unchanged.
