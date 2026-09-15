# macOS: the engine's own token spacing is authoritative

**Date:** 2026-09-15
**Scope:** `MacTranscriptionViewModel+Lines`, `LiveLineCursor`, `ParakeetTranscriberService`,
`CaptionsOverlayView`
**Origin:** ported from the same fix in the multi-platform sibling repo, which this project
was extracted from. The line-building code is shared ancestry, so the defect was shared too.

## The trap

The live transcript glues two words together as text finalizes (`"below"` + `"that,"` →
`"belowthat,"`). The obvious fix is to reuse `partialJoin`'s rule in the `.merge` path:
*if the open bubble doesn't end in whitespace and the incoming token doesn't start with
one, insert a space.*

That rule is unsound, because **Soniox tokenizes sub-word**. `"messy"` arrives as three
finalized tokens — `"m"`, `"ess"`, `"y"` — and the *only* thing distinguishing those
continuations from three separate words is the absence of a leading space. Applied to
every merge, it shreds ordinary speech:

> Ok ay. O h, it's still k ind of m ess y, but sor ry while we' re test ing.

**A token that starts without whitespace is a word continuation, not a missing
separator.** There is no information in a single token that separates the two cases.

## The invariant

The finalized path was already right, and the fix is to state its rule explicitly and
hold every other path to it:

> The transcript is the **verbatim concatenation** of the engine's token texts.
> Nothing is added, nothing is removed — except leading whitespace at a line start
> (a new bubble or paragraph), where the separator would render as an indent.

Under that invariant, spacing is whatever the engine sent, and no layer has to guess.
Three places violated it. All three are now fixed.

### 1. Whitespace-only tokens were silently dropped (the actual defect)

`commit()` opened with `guard !text.trimmingCharacters(...).isEmpty else { return }`,
so a token whose text is just `" "` vanished — and the next token's word glued onto the
previous one. That is `"below"` + `" "` + `"that"` → `"belowthat"` exactly, with no
provider bug required.

A whitespace-only token is now merged into the open bubble as a separator. It never
opens a bubble or paragraph (a separator with nothing to attach to is discarded rather
than opening a bubble on an indent), and `LiveLineCursor.noteSeparator()` records it
without consuming a pending endpoint — the *next* real token still lands on the break.

### 2. `partialJoin` injected a space the engine never sent

The live partial had its leading space stripped for display, then `partialJoin` guessed
one back whenever the bubble didn't end in whitespace. On Soniox sub-word partials that
guess is wrong: `"wat"` + `"er"` rendered `"wat er"` a beat before it committed as
`"water"`.

`partialJoin` is gone. `partialLine` holds raw engine text; `trailingPartial` appends it
verbatim; `standalonePartial` trims leading whitespace, because only it opens a line.
`commitPartialTail` commits the same raw string the views rendered. The emptiness test
that `partialJoin`'s callers implied is now a named `hasPartial` — "contains a
non-whitespace character" — since a partial that is nothing but a separator is not text
and must not make `stop()` think the session had content.

### 3. Parakeet's partial didn't match its own final

`ParakeetTranscriberService` graduates volatile text as `confirmed + " " + volatile` but
emitted the partial as bare `volatile` — the asymmetry `partialJoin` was papering over.
It now emits the partial with the separator it will graduate with, so concatenation
works for it too.

Nemotron (`FluidAudioStreamBridge`) already satisfied this: it cuts at a word start, so
the stable head keeps the trailing space. Soniox, SpeechAnalyzer, and the Core AI
Nemotron stream emit per-token spacing directly. All live engines now agree.

## What is left

The post-endpoint fallback in `mergedText` stays as a last-resort net: on the first token
after `<end>` — the one boundary where a sub-word continuation is impossible, since
Soniox emits it at a speech pause — a missing separator is restored. If the provider's
spacing is in fact self-consistent, the guard never fires. It is a net, not a heuristic
applied to normal text.

**Letter-to-letter glue with no endpoint and no dropped separator token would still be
unfixable here**, and is deliberately not guessed at. If the gluing recurs after this,
that is the signal that the provider stream itself is inconsistent — capture the raw
token stream before writing another heuristic, because inference is what produced the
sub-word shredding above.

See also `docs/2026-07-29-macos-live-line-building.md` for the per-token commit design
this invariant sits on top of.
