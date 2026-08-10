# macOS: search bar on the Transcriptions list

**Date:** 2026-08-10 · **Scope:** Open Captions only
**Related:** #25 (cross-session search / knowledge base) — this implements only
the substring-search half of that issue's Layer 1 ("Cross-session search");
see Scope below for what's deliberately left out.
**Status:** implemented. No test target — verified by re-reading every edited
call site; build/run verification is manual (Xcode only).

## Context

#25 asks for transcripts to be searchable rather than write-only, and lays out
two layers: (1) full-text substring search across transcript lines and
summaries, results grouped by session and deep-linking to the matching line,
and (2) retrieval-backed natural-language Q&A over the whole corpus. This note
covers a scoped-down slice of (1): a search field on the existing
Transcriptions list that filters sessions by title, description, summary, and
transcript-line text, and deep-links a transcript-text hit to that line.

## Scope

Deliberately **not** included, all still open against #25:

- The "ask a question" / retrieval + LLM layer, and the on-device-vs-cloud
  embeddings decision it requires.
- A dedicated `NavSection` sidebar destination — the request was to filter the
  existing Transcriptions list, not stand up a separate search screen, so the
  field lives in that list's own toolbar via `.searchable`.
- Tag-scoped filtering (#24) and CoreSpotlight indexing.
- Any backfill/index-maintenance job — see Decision 5 for why none is needed
  yet.

## Decisions

1. **Two very different costs, two very different mechanisms.** Title
   (`sessionTitle`), description (`shortDescription`), and summary
   (`summaryParagraphs`/`summaryKeyPoints`) all live directly on
   `TranscriptionSession`, which `TranscriptionsScreen` already fetches in
   full via its `@Query` to render the list — matching those fields in-memory
   (`TranscriptionsScreen.matches`) costs nothing beyond what's already
   loaded. Transcript-line text is the opposite: `lines` is a cascade
   relationship that's never faulted in for the list, and scanning it naively
   (`session.lines.contains { ... }` per row) would fault every session's
   entire transcript into memory on every keystroke. So line search instead
   runs as a `#Predicate`-pushed `FetchDescriptor<TranscriptionLine>` —
   `$0.text.localizedStandardContains(query)` — which the store executes as
   its own scan, only faulting in matching rows. `localizedStandardContains`
   also gives case/diacritic-insensitive matching for free, matching how
   `previewText` and friends already read.

2. **The line scan runs on a background `ModelContext`, off the main
   actor, and keeps the earliest match (plus a total count) per session.**
   `TranscriptSearchController` (`Services/Search/`) mirrors
   `DerivedFieldsBackfill`'s existing pattern: `Task.detached` + a fresh
   `ModelContext(container)`, never the view's main context, since
   `FetchDescriptor` execution is synchronous I/O. The fetch is sorted
   ascending by `startMs` and folded into
   `matchingLinesBySessionID: [PersistentIdentifier: LineMatch]` (session id
   → a small `LineMatch { firstLineID, firstLineText, totalCount }`),
   keeping the first line's id/text for deep-linking/excerpting and a
   running count of every line seen for that session — so a deep link
   always lands on the earliest mention, and the row can say "+2 more
   matches" without a second query. `firstLineText` is the one place actual
   line *text* (not just an id) crosses back from the background context —
   still just a `String`, never a model object, so `Sendable` isn't a
   concern.

3. **Deep-linking reuses the existing tap-to-seek plumbing instead of adding
   new highlight/scroll machinery.** `TranscriptionsScreen.open` checks
   `matchingLinesBySessionID` and, when the tapped session's hit came from
   transcript text, pushes a new `ContentRoute.sessionLine(session, lineID)`
   (alongside the existing `.session`) instead of `.session` alone.
   `MacSessionDetailView` gained a `scrollToLineID: PersistentIdentifier?`
   init parameter that seeds `tab` to `.transcript` and, once
   `playback.load` resolves `isAvailable` (synchronous — no race to await),
   calls the same `playback.seek(toMs:)` the manual tap-to-seek gesture
   already uses. `transcriptTab`'s `ScrollViewReader` (already there for
   playback auto-scroll) centers on the target line after a short settle
   delay, and the target line reuses the existing playback-active tint
   (`Color.accentColor.opacity(0.12)`) rather than a new highlight style —
   it just also lights up when `line.persistentModelID == scrollToLineID`,
   independent of whether playback is available at all (an imported session
   with no audio still gets the visual jump, just no seek). The highlight is
   intentionally permanent for the screen's lifetime (not a fade-after-N-
   seconds animation) and the scroll re-fires each time the user revisits the
   Transcript tab; the seek is one-time-only per visit, keyed off
   `session.persistentModelID` not changing across re-renders, so it doesn't
   fight a position the user has since scrubbed to themselves. `ContentRoute`
   is shared by `ActionItemsScreen`/`KeyPointsScreen` too, so both picked up
   a `.sessionLine` case in their exhaustive switch even though neither
   constructs one today.

4. **250ms debounce, 2-character minimum, before the line scan runs.**
   `TranscriptionsScreen.runLineSearch` sleeps 250ms inside a
   `.task(id: searchText)` (auto-cancelled by SwiftUI on the next keystroke)
   before calling `TranscriptSearchController.search`, so typing doesn't queue
   up one background scan per character. Below 2 characters the scan is
   skipped entirely and `TranscriptSearchController.reset()` is called instead
   — a 1-character `LIKE` scan matches close to every line in the store,
   which is expensive to compute and useless once computed. Title/
   description/summary matching has no such floor, since it's already free at
   any length.

5. **Stale-result guard, not just cancellation.** `Task.detached` isn't
   cancelled by the calling `.task`'s cancellation — only the *resumption* of
   the code awaiting it is skipped. So a slow scan for an old query could
   still finish after the user has typed something new. `TranscriptionsScreen.lineMatch(for:query:)`
   — the single place anything reads `matchingLinesBySessionID` — never
   trusts it unless `TranscriptSearchController.query` exactly equals the
   current (trimmed) search text, so a late-arriving stale result is
   silently dropped rather than flashing wrong matches, excerpts, or a
   deep-link into the wrong line.

6. **No persisted searchable index.** Unlike `previewText`/`durationMs`/
   `speakerNamesSummary` (cached once, kept in sync by every write path), this
   deliberately adds no new field or backfill: the live predicate scan already
   pushes the expensive part to SQLite instead of Swift, and keeping a
   denormalized blob in sync across every summary edit and every flushed line
   would be real complexity for a search that, at today's per-user data
   volumes, is already fast without it. If per-session line counts or total
   corpus size grow enough to make the scan noticeably slow, an FTS5-backed
   index — one of #25's own listed alternatives — is the next step, not this.

7. **The row's subtitle shows WHY a session matched, not just THAT it
   did — line excerpts win over summary, which wins over description; title
   matches don't get one at all.** `TranscriptionsScreen.searchResultExcerpt(for:query:)`
   replaces the plain description/preview subtitle with a highlighted
   excerpt (`Utility/Formatting/SearchSnippet.swift`) built around wherever
   the match actually is — a transcript line first (most specific/useful,
   per explicit product direction), else a summary paragraph/key point,
   else the description — and appends "+N more matches" for everything else
   that matched (other lines, or other summary/description fields; title
   is deliberately excluded from that count, since it's already visible in
   the row and isn't being replaced). A title-only match falls through to
   the ordinary subtitle unchanged, since there's nothing more specific to
   show. `SearchSnippet` finds the match with a literal
   `range(of:options:[.caseInsensitive, .diacriticInsensitive])` rather than
   `localizedStandardContains` (which has no API to report back *where* it
   matched) — the two searches can disagree in rare Unicode-normalization
   edge cases, in which case `SearchSnippet`'s failable initializer returns
   nil and the row silently falls back to the plain subtitle rather than
   showing a wrong/crashing highlight. The snippet itself is windowed
   (~40 characters either side of the match, "…" when trimmed) so a hit deep
   inside a long paragraph isn't cut off by the row's `.lineLimit`, and the
   matched substring renders via three concatenated `Text` runs (plain +
   bold-and-`Color.accentColor`-tinted + plain) rather than an
   `AttributedString` range conversion — simpler and avoids
   `String.Index`↔`AttributedString.Index` bridging entirely. The tint
   itself reuses `Color.accentColor` — the same system-adapting color the
   playback-active transcript line and onboarding already use — rather than
   a one-off fixed color, so a search hit reads as this app's existing
   "highlighted" language, not a new visual vocabulary; only the color is
   new versus `HighlightedMessageText`'s convention of leaving font/color
   for the caller.

8. **The list is a frozen snapshot, not a live re-derivation, specifically
   to avoid a debounce-driven flash.** `listContent` renders
   `TranscriptionsScreen.displayedSessions` (`@State`), not
   `filteredSessions` directly. The reason: `filteredSessions` depends on
   `searchController`, and re-deriving it on every keystroke would
   momentarily drop every line-only match (`lineMatch` correctly refuses to
   trust results for a query it hasn't caught up to yet — Decision 5) —
   which, if those were the only matches on screen, collapses the list to
   the empty state for a beat and then back, every single keystroke.
   `displayedSessions` instead only updates at explicit "settle points" via
   `refreshDisplayedSessions()`: `.onChange(of: sessions, initial: true)`
   and `.onChange(of: workspaceFilter)` (both instant/synchronous, no
   debounce risk) on the outer `NavigationStack`, and twice inside
   `runLineSearch` — immediately when a query drops below
   `minLineSearchQueryLength` (no scan needed), and once after the debounced
   scan actually finishes (guarded by `Task.isCancelled` so a superseded
   attempt never overwrites a newer one's result). Between those points the
   list simply doesn't move, which is the literal fix for the reported
   symptom: no re-render means no flash.

   A freeze needs every real mutation to have an explicit unfreeze, and one
   was missing at first: reassigning a session's workspace
   (`SessionExportCoordinator.reassignWorkspace`) sets `session.workspace` in
   place on an object `sessions` already holds — it doesn't insert, delete,
   or reorder anything, and SwiftData's `@Model` equality is identity-based,
   so `[TranscriptionSession]`'s `==` sees no difference and
   `.onChange(of: sessions)` never fires. Under an active workspace filter, a
   reassigned row would otherwise linger indefinitely (or fail to appear)
   until some unrelated event happened to refresh the list. Fixed two ways:
   `TranscriptionsScreen.workspaceMenu` (the row's own reassignment menu)
   calls `refreshDisplayedSessions()` right after `reassignWorkspace`, and a
   second `.onChange(of: path)` refreshes whenever the navigation stack
   returns to the list root — a safety net for `MacSessionDetailView`'s own
   workspace menu (same mutation, same invisibility to `sessions`, reached
   by a different screen this file doesn't otherwise observe) and, by the
   same reasoning, any other detail-view mutation that could affect
   filtering without this file finding out any other way.

10. **Accepted trade-off: results are a snapshot, not reactive to concurrent
   data changes.** `.task(id: searchText)` only reruns the line scan when the
   search text itself changes — not when a re-transcription
   (`PostSessionRetranscriber`) or file import rewrites a session's `lines`
   in the background while the same query stays typed. If that happens, the
   session's entry in `matchingLinesBySessionID` can point at a
   since-deleted line, or miss text that only exists after the rewrite,
   until the user edits the search box again (which forces a fresh scan).
   Title/description/summary matching doesn't have this gap, since those run
   in-memory against the live `@Query` array on every render. Not fixed here:
   correctly invalidating on "any session's lines changed" would mean
   observing `RetranscriptionManager`/`FileImportManager` completion as a
   second reactive trigger alongside `searchText`, which is more machinery
   than a narrow edge case (search open *and* a re-transcription/import
   completing *during* that same session) justifies today.
