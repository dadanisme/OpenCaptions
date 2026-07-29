# Live line building without the token accumulator (macOS)

**Date:** 2026-07-29
**Issue:** #16 — *Remove the token accumulator; build lines from engine output directly*
**Status:** implemented. The project has no test target, so the grouping/spacing logic was
verified by an out-of-tree simulation compiled against the real sources (see *The separator
invariant* below); everything else is manual (checklist at the end).

## What changed

`AccumulatorState` + `MacTranscriptionViewModel+Accumulator` are **deleted**. Finalized
tokens are no longer buffered in a sentence string and released at a punctuation
boundary — each one is committed into `TranscriberModel` the moment it arrives.

Two consequences drove the change:

- **Latency.** Nothing used to commit until a sentence end, a speaker flip, or a
  100-word runaway flush, so a long unpunctuated stretch sat invisible in the partial
  pipe. Now the transcript grows continuously.
- **One pipe for finalized text.** `partialLine` used to hold
  *finalized-but-uncommitted* text **plus** the engine's partial, so finalized words
  existed in two places at once. `partialLine` is now strictly the engine's
  un-finalized hypothesis.

## The contract, per engine

`onTokens(finals, partials)` → `commitFinalTokens(finals)` then
`updatePartialLine(partials)` (`+Engine.swift`). Finals commit **before** the partial
is published, so the live view never shows the same words twice.

| | Soniox (cloud) | Nemotron / Parakeet (on-device) |
|---|---|---|
| Who segments | Nothing does. Every final token is committed as it arrives. | `FluidAudioStreamBridge` — the **sole** owner. One final per completed sentence, plus the stable head of an unpunctuated run. |
| Speaker | Per-token `speaker` (diarization on). | `TranscriptionToken.unknownSpeaker`; single stream. |
| Paragraph-break signal | `<end>` endpoint tokens **and** token-final punctuation. | Token-final punctuation (no endpoint signal exists). |
| Line timestamps | The token's `start_ms`/`end_ms` — audio-stream offsets, so they map straight to a file offset for playback seek. | The session clock (`totalActiveTime`); the engines report 0/0. |
| Live partial | Whatever Soniox still has in flight. | The last `keepTailWords` (8) words. |

`resolvedTimes(startMs:endMs:)` in `+Lines` is the single place that switch is made,
keyed on `capabilities.providesReliableTimestamps`.

### On-device: what the bridge stopped doing

`FluidAudioStreamBridge.tokens(forFull:confirmedPrefix:)` used to hold the tail back
until punctuation arrived *or* it passed `maxAccumulatorWords` (100). It now finalizes
everything except the last 8 words, unconditionally, so offline mode gets the same
continuous commit behaviour as Soniox. `promoteIfTooLong` became
`splitKeepingTail(_:words:)`; the sentence split stayed, because it is what lets the
view model break paragraphs exactly at Nemotron's native punctuation instead of at an
arbitrary token boundary. The *duplication* (view model re-grouping what the bridge had
already grouped) is what went away.

## Grouping: `LiveLineCursor`

Grouping is now a decision made **at commit time** about text that is already visible,
not a reason to withhold it. `LiveLineCursor` holds **no text** — only where the
transcript stands:

```
speaker? · sourceApp? · paragraphWords · closedParagraphs
didEndSentence · didEndWithWhitespace · didSeeEndpoint
```

For each finalized token it returns `.merge` / `.newParagraph` / `.newBubble`:

- **`.newBubble`** — no bubble open yet, or the speaker changed, or the dominant
  source app changed.
- **`.newParagraph`** (`\n\n`) — the paragraph passed `maxWordsPerParagraph` (50) *and*
  the token lands on a safe break (previous token closed a sentence, or an `<end>`
  arrived). Past `maxParagraphsPerBubble` (3) this promotes to `.newBubble`.
- **`.merge`** — everything else.

Three rules keep it from producing garbage:

- **Never split a word.** A break is only allowed at a *breakable seam* — whitespace on
  either side of it. Which side carries the separator depends on the engine (see below),
  so testing only the incoming token would have blocked **every** break on the on-device
  path. Spaceless scripts (CJK) break anywhere, which is correct for them.
- **Punctuation follows its text.** A token with no letters or digits
  (`SentenceHeuristics.hasWordContent`) always merges and counts as zero words, whatever
  speaker the engine attributed it to. Engines sometimes hand a bare `"."` a different
  speaker id; splitting there would strand a one-character bubble.
- **A last-resort ceiling.** `paragraphCeilingWords` (200) breaks even without a
  breakable seam, so no bubble can grow without bound if an engine never offers one.

### The separator invariant (load-bearing)

`TranscriberModel.appendOrAdd` concatenates raw — it inserts no separator — so the
committed text depends entirely on the engine's own spacing, and **the two engines put it
on opposite sides**:

| | separator | example finals |
|---|---|---|
| Soniox | **leading** on word tokens | `" hello"`, `" there"`, `"."` |
| `FluidAudioStreamBridge` | **trailing** (it cuts at a word start, so the stable head ends with the space before the cut) | `"Hello "`, `"everyone "` |

So when a token opens a bubble or a paragraph, `commit` strips only its **leading**
whitespace. Trimming both ends — the obvious thing to write — silently glues the next
on-device token onto this one's last word (`"alpha beta"` + `"gamma "` →
`"alpha betagamma "`), corrupting the live view, the SwiftData row, and the Firestore
mirror at every break in Offline Mode. Same reason `commitPartialTail` supplies a leading
space only when the open bubble ends on a word character: unconditionally prepending one
doubles the space after an on-device final.

Both hazards were caught by an adversarial review of this change, then pinned down with a
simulation that compiles `LiveLineCursor` + `SentenceHeuristics` +
`FluidAudioStreamBridge` verbatim and asserts that the committed word sequence equals the
spoken one for Soniox, punctuated on-device, unpunctuated on-device, and CJK input. If you
touch the spacing logic, re-run that kind of check — a build won't catch it and neither
will reading the diff.

### Presentation caps: deliberately kept

`maxWordsPerParagraph` (50) and `maxParagraphsPerBubble` (3) are **preserved**, and
`maxAccumulatorWords` (100) was renamed `maxWordsWithoutSentenceBreak` and kept as the
hard cap that breaks a paragraph with no punctuation in sight. Not cosmetic: the
in-memory hot window flushes to SwiftData on **line count** (`flushThreshold = 70`), so
without caps a long single-speaker session would be one unbounded bubble that never
flushes. The same constant also bounds a runaway sentence in the batch
`PostSessionSegmentBuilder`, so it now names the shared idea rather than a deleted type.

Dropped as genuinely dead: `maxCharsPerParagraph` and `maxStreamingParagraphChars`,
tunables for a diarization-off streaming path this app never had.

### Source-app attribution

`appMonitor?.dominantApp(fromMs:toMs:)` is queried only when
`LiveLineCursor.needsSourceAppRefresh(for:speaker:)` says so — a bubble opening, a safe
break, or a mid-sentence speaker change — never on a plain merge, which inherits the open
bubble's app. That keeps one app per bubble (a mid-turn app switch still splits it, at the
same sentence granularity as before) and keeps an `O(samples)` scan off the per-token
path. The speaker-change case matters: without it, a bubble opened mid-sentence by a
speaker flip would inherit the *previous* speaker's app, which the deleted `flushSentence`
never did because it re-read the app for every committed line.

## The partial renders as the open bubble's tail

Committing per token made the *view* inconsistency visible: Soniox holds finalization for
seconds, so its partial appeared as a visibly separate grey block below the bubble, while
the on-device path (an 8-word tail on top of continuous finals) already read as one
flowing line. Both now render the same way — the partial is concatenated onto the **last
bubble's tail**, dimmed, in the same paragraph.

`Text + Text` is what makes it one paragraph; two sibling views wrap to a new line, which
is the whole thing being avoided. So `HighlightedMessageText` exposes `asText` and the
views concatenate:

```swift
HighlightedMessageText(committed, userName:).asText        // cached: keeps its @Name highlight
    + Text(partial).foregroundStyle(.secondary)            // ephemeral, uncached
```

Folding the partial into `message` instead would have been simpler and wrong: the string
would change every token, forcing `cached: false` on the committed part too, which
disables name highlighting — on the one bubble the user is actually reading.

**The partial still stands alone when it can't continue a bubble** (`standalonePartial`):
nothing committed yet, or the engine attributes it to a **different speaker** than the
open bubble. Showing speaker 2's in-flight words inside speaker 1's bubble would be a
mis-attribution, not a continuation. An *unattributed* partial (`partialSpeaker == nil`,
always the case on-device) continues the bubble. `partialSpeaker` therefore became
observed — the views read it through `trailingPartial`, so they must re-render when it
changes.

The join between bubble text and partial is `partialJoin`, the single place that rule
lives; `commitPartialTail` commits with the same value, so **what the user reads in flight
is byte-identical to what gets saved**. The simulation asserts exactly that, stepping
words from partial to final under both engine spacing conventions.

Auto-scroll pins the last bubble's row rather than a `"partial"` row whenever the partial
is a tail, since that row is what grows.

**Not changed: the web client.** The Firestore wire format is untouched — the session
doc's `accumulator` field still carries the partial separately, and the web still renders
it as its own preview bubble. That is the web client's rendering choice, and this repo
doesn't contain it.

## `speaker == -1` no longer means two things

It now means exactly one: *diarization unavailable*, named
`TranscriptionToken.unknownSpeaker`. The accumulator's second meaning — "no speaker
claimed yet" — is expressed by `LiveLineCursor.speaker` being `nil`.

## Firestore: the write cadence had to change with it

`mirrorCommittedLine` fires once per finalized token now, not once per sentence, so
`FirestoreSyncService.appendOrUpdateLine` coalesces **same-bubble** growth at
`lineUpdateMinInterval` (1 write/sec) with a trailing flush, and forces that flush when
the next bubble opens or the session pauses/ends. A *new* bubble always writes straight
through. Without this, a shared session would have written a Firestore document several
times a second.

The session doc's `accumulator` field — an unrelated, pre-existing name: it is the web
client's typing-preview channel — keeps working and keeps its name. It now carries
**only** un-finalized text, so the web no longer renders the same words in both the
preview and a line document.

## Name-mention alerts

`MacNameMentionNotifier.handle(finalizedLine:)` became
`handle(finalizedFragment:)`. Per-token matching would miss a name split across tokens,
so the notifier keeps a 240-character rolling window of recently finalized text, clears
it whenever a mention is detected (including one the 5 s debounce suppresses, so a
matched name can't re-fire later from stale text), and caches the compiled regex because
it now runs per token.

## Other decisions worth recording

- **The partial is unthrottled.** The old `updatePartialLine` gate was ~5 fps and added
  up to 200 ms of latency; finalized text no longer queues behind it and the partial is
  now short, so rendering every frame is cheaper than the throttled version used to be.
  The Firestore write stays throttled inside the service.
- **`SentenceHeuristics` stays shared** between the live cursor and
  `PostSessionSegmentBuilder` rather than being retired or handed to the batch builder
  alone. Both still need CJK-aware word counting and sentence-end detection, and
  duplicating them is how the two paths would drift. Its header now describes that
  arrangement instead of the deleted accumulator.
- **Segment-cache churn was measured and accepted.** The last bubble's string now
  changes ~3x/s instead of once per sentence, so `HighlightedMessageText`'s shared
  segment cache (200 entries, evicts half when full) turns over faster and visible
  committed lines occasionally re-parse. Worst case is ~20 re-parses of <=2 KB strings
  every ~33 s — not worth the alternative, which would mean rendering the live bubble
  with `cached: false` and thereby dropping its name-mention highlight, the one bubble
  the user is actually reading.
- **`saveTranscriptionLine` was relocated, not deleted** — it is the persistence funnel
  (in-memory model → Firestore mirror → debounced SwiftData flush → first-flush session
  creation). It now lives in `MacTranscriptionViewModel+Persistence.swift`.

## Files

- **New:** `ViewModel/LiveLineCursor.swift`, `ViewModel/MacTranscriptionViewModel+Lines.swift`,
  `ViewModel/MacTranscriptionViewModel+Persistence.swift`.
- **Deleted:** `ViewModel/AccumulatorState.swift`,
  `ViewModel/MacTranscriptionViewModel+Accumulator.swift`.
- **Changed:** `MacTranscriptionViewModel.swift` (state + `stop()`), `+Engine.swift`,
  `+Firestore.swift`, `Model/TranscriptionToken.swift`,
  `Utility/OnDeviceModels/FluidAudioStreamBridge.swift`,
  `Utility/Formatting/SentenceHeuristics.swift`, `Utility/TranscriptionConstants.swift`,
  `Utility/NameMention/MacNameMentionNotifier.swift`,
  `Services/Sync/FirestoreSyncService{,+LineSync}.swift`,
  `Services/Transcription/OnlineTranscriberService{,+Messages}.swift`,
  `Services/Transcription/NemotronTranscriberService.swift`,
  `Services/Retranscription/PostSessionSegmentBuilder.swift`.
- **Changed (views + model):** `Model/TranscriberModel.swift` gains `revision`, bumped on
  every `appendOrAdd`; `MacLiveTranscriptionView` / `CaptionsOverlayView` add an
  `.onChange(of: finalLines.revision)` auto-scroll pin. Needed because committed text now
  often grows *in place* on the last bubble without `ids.count` or `partialLine` changing,
  and the old pin signals would have left the newest words below the fold. Their rendering
  is otherwise unchanged: still committed bubbles plus a partial bubble; only what
  `partialLine` *contains* changed.
- **Untouched:** the batch paths (post-session re-transcription, file import) never used
  the accumulator.

## Manual verification checklist

No tests exist in this project, so these are the safety net:

1. **Multi-speaker Soniox session** — bubbles split on speaker change; punctuation never
   starts its own bubble; renaming a speaker still relabels every one of their bubbles.
   The dimmed in-flight text should extend the newest bubble's last line rather than sit
   below it — **except** when a new speaker starts, where it gets its own row until it
   commits.
2. **Long unpunctuated speech** — text keeps appearing (no stall until a flush); a
   paragraph break lands by ~100 words without splitting a word.
3. **Offline Mode (Nemotron)** — text appears continuously with no punctuation needed;
   the live tail stays short; timestamps advance with the session clock.
4. **Mid-turn app switch** (system-audio capture) — the bubble splits and each half
   shows the right app glyph.
5. **Stop & Save mid-sentence** — the in-flight tail is kept, attributed to the right
   speaker, and no name-mention alert fires as the session ends.
6. **Shared session** — the web client's lines keep up (≤1 s behind), the preview bubble
   shows only in-flight text, and the last bubble is complete after Stop.
7. **Pause / resume and a live mic↔system source swap** — the open bubble survives both.
