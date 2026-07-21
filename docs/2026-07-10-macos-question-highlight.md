# macOS transcript question highlighting (parity with iOS)

**Issue:** #254 · **Target:** OgmoMac (native macOS app)

Ports the iOS "highlight sentences that end in `?`" transcript treatment to the
standalone macOS app so questions stand out at a glance, live and in saved
sessions. Detection is purely string-based — **no** `TranscriptionLine` change and
**no** model flag, matching iOS.

## What shipped

- **`OgmoMac/Views/SessionDetail/HighlightedMessageText.swift`** — a `View` that renders a
  transcript string, tinting question sentences. Fast-paths to a plain `Text` when
  there is nothing to highlight (the common case), so non-question lines render
  byte-for-byte as before.
- **`OgmoMac/Views/SessionDetail/HighlightedMessageText+Caching.swift`** — the sentence scanner
  (`findQuestionRanges`, verbatim from iOS), `buildSegments`, `buildAttributedString`,
  and a 200-entry segment cache. Split out to respect the 250-line limit.
- **`OgmoMac/Views/Common/DesignTokens.swift`** — a new macOS design-token namespace whose
  only member today is `Color.DS.questionHighlight`.
- Five render sites swapped from `Text(...)` to `HighlightedMessageText(...)`:
  saved-session playback rows, live committed bubbles, the live partial line, and
  both captions-overlay sites (committed + partial).

## Decisions & why

### 1. Question-highlight only — name highlighting was dropped
The iOS `HighlightedMessageText` does two things: highlight the signed-in user's
**name mentions** (red text via `\b<userName>\b`) *and* highlight question
sentences. macOS has **no `UserSettings` / no per-user name concept** in the
transcript UI, so name highlighting has no input and no consumer. It was dropped
entirely: no `findNameRanges`, no regex cache, no `.nameHighlight` segment type.
The issue's own function list (`findQuestionRanges`, `buildSegments`,
`buildAttributedString` — not `findNameRanges`) reflects this.

### 2. Font & foreground are inherited, not set on the runs
iOS sets an explicit `Font.system(.body, design: .rounded)` and a per-segment
foreground on every `AttributedString` run, because its `SpeakerBubble` forces
`baseTextColor: .black` for the yellow-on-light look. macOS instead leaves the
runs' font/foreground **unset**, so the surrounding view's `.font(.transcript(...))`
(size-scaled per `TranscriptTextSize`) and foreground style (`primary` /
`.secondary`) are inherited. This makes `HighlightedMessageText` a true drop-in for
plain `Text(line)` — sizing and color are unchanged; only a background tint is
added on question sentences. It also means the size-scaling and the `.secondary`
partial-line dimming keep working with zero extra plumbing.

### 3. `buildSegments` simplified to merge-then-interleave
iOS merges two overlapping highlight dimensions (name + question) via a sorted
point-list with active-flag tracking. With only one dimension, macOS instead
**merges overlapping/adjacent question ranges** into disjoint sorted spans, then
interleaves normal/highlighted text. Nested quotes containing more than one `?`
(e.g. `"Really? Are you sure?"`) can yield overlapping ranges; merging guarantees
the output never duplicates, drops, or reorders text. (In that same nested case the
iOS point-merge silently un-highlights the tail; the macOS merge highlights the
whole quoted span — a small, defensible improvement.)

### 4. Highlight color = a translucent tint of the emphasized-selection color
`Color.DS.questionHighlight` is a **translucent `.selectedContentBackgroundColor`** —
the vivid selection color (a saturated tint of the user's accent) at partial alpha
(~0.32 Light / ~0.45 Dark). The highlighted run's text is left **inherited** (dark in
Light, light in Dark) — never forced white — so it stays legible on the tint.

This landed after iterating through the alternatives:
- iOS's fixed pale amber (`0xFFF3CD`) — too subtle on the Mac.
- `.selectedTextBackgroundColor` (the gentle "Highlight color" from Appearance) —
  still a soft pastel tint of the accent (a pale pink on a red-accent Mac).
- Full-opacity `.selectedContentBackgroundColor` with white text — too loud, and the
  forced-white text is wrong in Light.

The translucent middle keeps the accent-following, appearance-adaptive behavior of
the selection colors, but with enough presence to catch the eye and enough softness
to keep the inherited text readable in both modes. The alpha is a touch higher in
Dark, where a tint over a dark row reads weaker.

### 5. Applied to the captions overlay too
The issue left this open. The whole point of the feature is *at-a-glance*
recognition, and the floating captions strip is the most glanceable surface, so
both its committed lines and its partial line use `HighlightedMessageText`.

### 6. The streaming partial line bypasses the segment cache
`parseMessage()` memoises segments in a shared 200-entry `segmentCache` keyed on the
line text. The live **partial** line streams a fresh string on every token, so
caching it would insert hundreds of never-reused keys and evict the still-visible
committed-line entries. The two partial sites therefore render with
`HighlightedMessageText(partial, cached: false)`: they parse fresh each tick but
never touch the cache, so only stable committed lines populate it. This mirrors
iOS, which likewise keeps its streaming tail out of the cache (there via a separate
un-keyed trailing run). Surfaced by the port's adversarial review.
