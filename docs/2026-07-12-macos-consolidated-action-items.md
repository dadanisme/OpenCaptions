# macOS: Consolidated Action Items view (read-only rollup)

**Date:** 2026-07-12 · **Scope:** Open Captions only

## Problem

Action items are generated per-session by the AI summary (`SummaryService`) and
stored as SwiftData `ActionItem` rows on their `TranscriptionSession`. They were
only visible one session at a time in `MacSessionDetailView`, so the app couldn't
answer "what do I still need to do across all my meetings?"

## Solution

A new **Action Items** sidebar section that presents a **read-only aggregation**
of action items across all of the signed-in user's sessions.

- **Files:** `OpenCaptions/Views/ActionItems/ActionItemsScreen.swift` (screen +
  grouping + toggle) and `ActionItemRow.swift` (one row). Wired via a second
  `NavSection` case in `ContentView.swift`.
- **Organization:** grouped by source session — the section header shows the
  session title + date; items render newest-session-first, `sortOrder` within.
  Both pending and completed items show (completed render checked + struck).
- **Interaction:** tapping an action-item row toggles `isCompleted` (persisted
  immediately via an explicit `save()`) — **the only mutation**. Tapping the
  session's group header row pushes the source session's `MacSessionDetailView`.
- **Scoping:** `ActionItemsScreen(userId:)` builds the `@Query` predicate from the
  captured uid, identical to `TranscriptionsScreen(userId:)`. The data source is
  user-scoped sessions filtered to those with a non-empty `actionItems`.
- **Empty state:** `ContentUnavailableView` when the user has no action items.

## Decisions & trade-offs

- **Query sessions, not `ActionItem` directly.** Grouping is the primary UI
  concern, so scoping + newest-first ordering reuse the exact `TranscriptionsScreen`
  predicate pattern; grouping is then trivial (one `Section` per session). Filtering
  to non-empty `actionItems` happens in-memory (the set is small).
- **Own `NavigationStack`, reused route.** The screen carries its own stack but
  reuses the existing `ContentRoute.session` destination and `MacSessionDetailView`,
  so session detail behaves identically whether reached from Transcriptions or here.
- **Whole row toggles; header opens.** The entire item row is the toggle
  affordance (the checkmark is a plain indicator, not a button); opening the source
  session is the group header row's tap. This keeps the two gestures on separate
  rows so neither bubbles into the other.
- **Local persist only.** Toggling completion writes SwiftData; no Firestore sync
  (there is no existing action-item write path to mirror, and the rollup is
  intentionally read-only otherwise).

## Out of scope (possible follow-ups)

- Editing text, delete, reorder, user-created (non-AI) action items.
- Pending-only filtering / a flat cross-session task inbox.
