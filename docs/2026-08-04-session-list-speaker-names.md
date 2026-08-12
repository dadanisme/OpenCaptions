# macOS: speaker names on every session list row

**Date:** 2026-08-04 · **Scope:** Open Captions only · **Closes:** #27
**Related:** the pre-extraction design note `2026-06-02-home-screen-derived-fields.md`
(referenced by `TranscriptionSession+Derived.swift` — never carried over into this repo;
treat this note as the current source of truth for that file instead),
`docs/2026-07-29-macos-speaker-auto-naming.md` (why speaker names can arrive
after a session is first saved)
**Status:** implemented. No test target — verified by re-reading every edited
call site; build/run verification is manual (Xcode only).

## Context

The Transcriptions, Action Items, and Key Points list rows showed only a title
and a date (plus an AI subtitle on Transcriptions) — no indication of who was
in the session. Issue #27 asked for a truncated "who was here" summary on every
row (e.g. `Yoga, Abby, and 2 more`), rendering nothing for non-diarized
(Offline Mode) sessions.

## Decisions

1. **Cached field, not a per-row scan.** `TranscriptionSession.speakerNamesSummary`
   mirrors `durationMs`/`previewText`: a `String?` where `nil` means "not yet
   computed" (legacy row) and an empty string means "computed, no diarized
   speakers" (render nothing). A naive implementation scanning `session.lines`
   per visible row would regress list scrolling exactly as those two fields'
   doc comments already warn against.

2. **Recomputed on every write, unlike `previewText`.** `previewText` is
   captured once from the first flush and frozen — a session's opening lines
   don't change. Speaker identity can, though: a new speaker can appear later
   in a long session, and a name can arrive well after the session is first
   saved (via the summary auto-naming pass or a manual rename). So every write
   site recomputes `speakerNamesSummary` unconditionally rather than guarding
   on `nil`: both `TranscriberModel+Persistence.swift` flush/finalize sites,
   `PostSessionRetranscriber.replaceTranscript`, and — the one that matters
   most for staying in sync — `SpeakerRenamer.apply(_:to:context:)`, the single
   write path both auto-naming and the two manual rename sheets go through.

3. **Truncation rule: prefer named speakers over generic placeholders when
   picking the two visible names.** `TranscriptionSession.makeSpeakerNamesSummary(from:)`:
   - 0 speakers → `""` (render nothing).
   - 1 speaker → just that name.
   - 2 speakers → `"A and B"` (no truncation, both always shown — even if one
     is still a generic `Speaker N`, since there's nothing to fold into a
     count with only two).
   - 3+ speakers → partitions into named (not `SpeakerLabel.isDefault`) vs.
     generic, concatenates named-first (each group keeping its own
     first-appearance order), takes the first two as `shown`, and folds the
     rest into `", and N more"`. This is what guarantees a 4-speaker session
     with only two named speakers reads `Yoga, Abby, and 2 more`, never
     `Yoga, Speaker 3, and 2 more` — but if nothing is named yet (a
     freshly-stopped session, pre-summary), it falls back to showing generic
     labels in those two slots rather than blocking the row; it fills in once
     the summary lands, same as any other rename.

4. **One shared distinct-speakers scan.** `SpeakerLabel.distinctSpeakers(from:)`
   (first-appearance order, `speakerId > 0` only, names via the existing
   `display(_:id:)`) replaced two of the three pre-existing duplicate
   implementations: `MarkdownFormatter.distinctSpeakerNames` and
   `MacSessionDetailView+SpeakerEditing.editableSpeakers` (the latter also
   picked up a small correctness fix — it used to hardcode `"Speaker \(id)"`
   instead of going through `SpeakerLabel.display`). `SessionLinkSharer`'s
   speaker map was deliberately left alone: it needs a full `[Int: String]`
   map including non-positive ids with last-write-wins semantics for
   Firestore backfill parity, which isn't the same thing as "distinct named
   speakers for display."

5. **Legacy backfill.** `DerivedFieldsBackfill.run(container:)` (modeled on
   `SessionOwnerBackfill`'s shape) fetches every session with a nil
   `speakerNamesSummary` and calls the existing `recomputeDerivedFields()` on
   each — which, as a side effect, also finally backfills `durationMs` /
   `previewText` for any row that predates those fields, since nothing
   previously called that function. Runs from `OpenCaptionsApp`'s launch task
   alongside `SessionAudioOrphanSweep`.

6. **Plain text, no per-speaker color chips.** The issue's own "Alternatives
   Considered" section rejected initials/avatar chips for legibility; this
   follows that conclusion — a single `Text` (`SessionSpeakersLine`), not a new
   chip component. `SessionHeaderRow` also consolidates the Action Items and
   Key Points lists' previously byte-identical `sessionHeader` row into one
   shared view, since both needed this same change.
