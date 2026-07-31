# macOS Always-On Markdown Export

**Date:** 2026-07-31 · **Scope:** Open Captions (native macOS) only · **Issue:** [#15](https://github.com/dadanisme/OpenCaptions/issues/15)

Mirrors every session to plain markdown files in a folder the user picks, continuously
and without being asked. Before this, a transcript existed only inside the SwiftData
store (plus the Firestore mirror for sharing) — unreachable from `grep`, an editor,
Obsidian, git, or an LLM pointed at a folder, and gone if the container was reset.
Getting text out meant remembering to Copy as Markdown or export a summary PDF, both
one-off and per-session.

```
<export root>/
  2026-07-29-weekly-standup/
    transcript.md
    summary.md          ← only once a summary exists
    audio.m4a           ← only when session audio was kept
  2026-07-28-client-call/
    transcript.md
```

## The sandbox is the whole design problem

Everything awkward here follows from one fact: **the app is sandboxed and
`~/Documents/Open Captions` is outside its container.**

`com.apple.security.files.user-selected.read-write` — the entitlement the PDF export
already relies on — grants access for the lifetime of a Powerbox grant. That is enough
for `NSSavePanel`, which writes once and forgets. It is *not* enough for a folder chosen
once and written to on every save for months. A remembered **path string** would simply
stop being writable at the next launch.

So the destination is persisted as an **app-scoped security-scoped bookmark**
(`opencaptions.markdownExport.bookmark`, `Data`), which needs a second entitlement:

```xml
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

Resolved back to a URL at launch, re-minted when macOS reports it stale (the folder was
renamed or moved), and dropped in favour of the default when it can't be resolved at all
(deleted, or on an unmounted volume). Every read and write is bracketed by
`startAccessingSecurityScopedResource()` / `stop…`, which is what `ExportRoot.withAccess`
exists to make unforgettable.

The bookmark key is deliberately **not** in `register(defaults:)` — a blob has no sensible
registered default, and its *absence* is precisely the signal for "still on the default
location". Same reasoning as `vocabularyTermsKey`.

### The open sub-decision: the default location

Issue #15 left this open — "either fall back to `Application Support/…` inside the
container, or prompt for the folder at first save. Pick one and document it."

**Chosen: fall back inside the container, to `<container>/Documents/Open Captions`.**

- **Not a first-save prompt.** Export is meant to be *always on*. A modal on the first
  save turns "your transcripts are also files" into a decision the user has to make while
  they are trying to finish a session, and a Cancel would leave the feature permanently
  half-off with nothing to show for it.
- **`Documents`, not `Application Support`**, even though `SessionAudioStore` uses the
  latter and is otherwise the model for this code. Application Support is for app-managed
  state the user never opens; these are documents the user is explicitly meant to read.
  It also makes the container layout identical to what they get after Browse…, so nothing
  about the files changes when they move.

The honest cost is that the container path is awkward to reach in Finder, so the Settings
footnote says so in as many words and nudges toward Browse…, and a **Reveal** button opens
it directly rather than asking anyone to type `~/Library/Containers/…`.

## Always on, no toggle

There is no "enable export" switch. Browse… changes *where* files go, never *whether*.
This is a deliberate departure from the neighbouring rows in Settings → General, which are
all toggles: writing a few kilobytes of markdown has no cost worth gating, no network, no
battery, and no privacy surface beyond the disk the transcript already lives on. A toggle
would only create a state where the archive silently stops being an archive.

## Files are rewritten, never appended

Every mutation site re-renders the whole folder. Disk is a *projection* of SwiftData, not
a second source of truth — which is what makes the write idempotent and lets any missed
hook be repaired by the next one.

| Site | What lands |
|---|---|
| `MacTranscriptionViewModel.stop()` | first write after a live session |
| `FileImportManager.run` (end) | imported file; also settles the audio mirror after the retention branch |
| `SummaryViewModel.generateSummary` | `summary.md` appears; the retitle **renames the folder** |
| `PostSessionRetranscriber.replaceTranscript` | new transcript; **removes** the now-stale `summary.md` |
| `SpeakerRenamer.apply` | per-line labels + the `**Speakers:**` header |
| `ActionItemsScreen.toggle` | `- [x]` completion state in `summary.md` |
| `OpenCaptionsApp` launch task | backfill of anything never exported |

Two of these are worth spelling out:

- **A cleared summary is expressed as `nil`, not as an empty file.**
  `MarkdownFormatter.formatSummary` returns `String?`, and nil tells the writer to *delete*
  `summary.md`. That is the entire mechanism behind "re-transcription removes the stale
  summary" — no special-case call, just the same export running against a session that no
  longer has one.
- **`ActionItemsScreen.toggle` is a mutation site** the issue didn't list. Completion state
  is rendered into `summary.md` as GFM task-list items, so a checkbox tap that didn't
  rewrite the file would leave disk quietly wrong.

**Manual title edits are listed in the issue but do not exist.** There is no rename UI for
a session today — `sessionTitle` is written only by `saveSession` and by the summary
retitle, both covered. When a rename UI is added it must call
`SessionExportCoordinator.export`.

## `exportFolderName` — why a new stored field

A session has no stable identifier: `cloudSessionId` is nil unless the session was shared,
and `persistentModelID` is neither durable nor printable. Without one, a retitle can only
*create* the new folder — it cannot know which old one to rename, so it orphans it, and a
delete cannot know what to clean up.

So `TranscriptionSession` gains an optional `exportFolderName: String?`, mirroring
`audioFileName` exactly: **only the relative reference is stored**, the absolute URL is
resolved at write time, and additive-optional means SwiftData lightweight migration handles
existing stores with no `SchemaMigrationPlan`.

It is also what makes the destination change cheap — folder names are preserved by the
move, so relocating rewrites no rows at all.

### Naming and collisions

`<yyyy-MM-dd>-<slug>`, so a Finder listing sorts chronologically with nobody touching a
sort column. The date is formatted with an **`en_US_POSIX` fixed format** — the app's other
date strings use `DateFormatter.localizedString`, which in some locales emits `29/07/2026`:
wrong sort order and a path separator in a filename.

Slugs are lowercased, non-alphanumerics collapse to a single hyphen (which removes `/` and
`:` as a side effect rather than as a special case), leading dots can't survive so nothing
lands hidden, and the length is capped at 60 characters — trimmed back to a hyphen boundary
when one is close, so a name ends on a whole word. A title with no usable characters at all
(emoji-only) falls back to `session`.

Collisions get `-2`, `-3`, … and are checked against **both** the filesystem and an
in-memory `claimed` set. The set is not redundant: the writer is asynchronous, so two
sessions saved back-to-back with the same day and title would both pass `fileExists` before
either folder existed and pick the same name.

**Every export re-resolves the name from scratch** — there is no "the old folder already
starts with the new name, keep it" fast path. Such a check looks like a cheap way to
preserve a `-2` suffix, but `hasPrefix` also matches every retitle that *shortens* a title
("Client call with Acme" → "Client call"), which are exactly the ones that must rename; the
folder would then be frozen under the old name forever, since the stamp never changes and
the next export takes the same branch. It is also unnecessary: for a genuine dedupe,
`resolveCollision(desired, keeping: previous, …)` finds the un-suffixed name still occupied
by the neighbour that owns it and lands back on `previous`. One extra `fileExists` per
export buys correctness.

## Concurrency: snapshot on the model's actor, write on an actor of its own

A `TranscriptionSession` is a SwiftData `@Model` — not `Sendable`, and valid only on the
context that vended it. It can therefore never be handed to a background writer. The
markdown is rendered *wherever the session lives* (the main actor for a live save, a
background `ModelContext` during backfill) into a plain `Sendable` `SessionExportSnapshot`,
and only that crosses the boundary.

`SessionMarkdownWriter` is an `actor` for two reasons, and the second is the less obvious
one:

1. It keeps file I/O — including a 14 MB audio copy — off the main actor.
2. It **serializes**. A summary landing while a re-transcription is still writing would
   otherwise race on the same folder.

Nothing in the writer throws to its caller. An export must never be able to fail a session
save, so failures are logged and the SwiftData row remains the source of truth. This is the
same contract `SpeakerRenamer` operates under and for a related reason: one of the callers
here is `PostSessionRetranscriber`, running on a throwaway `SummaryViewModel` whose errors
nobody reads.

Two write-amplification guards, because a session is re-exported on every summary, rename,
and checkbox tap:

- Text is written only when it **differs** from what's on disk, so a no-op re-export doesn't
  bump the modification date and churn Finder, Spotlight, and any folder watcher.
- The audio copy is skipped when size **and** mtime already match.

## Audio is mirrored too

Requested on the issue after the fact. The copy sits beside the markdown as `audio.m4a`;
`SessionAudioStore` remains the source of truth and the playback path, and this is purely a
mirror. When a session has no audio — recording off, or an import that dropped the file per
the retention setting — the same export **removes** the stale copy. It costs a second copy
of every recording (~14 MB/hour), which is the point: the folder is meant to be a complete,
self-contained archive that outlives the app.

## Backfill and relocate

- **Backfill** runs in the launch task, exporting every session whose `exportFolderName` is
  nil. On the first launch after this ships that is the whole library; afterwards it is an
  empty fetch that also self-heals an export interrupted by a quit. It commits each name
  **before** writing that folder — batching the saves to the end would mean a quit
  mid-backfill leaves folders no row claims, and the next launch would read them as
  collisions and rewrite everything as `-2`.
- **Relocate** moves the existing folders to the newly chosen root rather than copying or
  re-exporting, so the old location is left clean.

`relocateAll` reads the **old root's directory listing**, not SwiftData. Settings can be
opened without the main window ever existing, and the main window's `.task` is what hands
`LiveSessionStore` the shared `ModelContainer` — so no container is guaranteed to be in
hand. The folders are a complete record of what needs moving anyway.

Three guards on the move, each protecting against something that would destroy user data:

- **A subfolder counts as ours only if it contains a `transcript.md`.** The previous root
  may be a folder the user picked and keeps other things in, and moving those would be
  theft. The same test authorises clearing an occupied *destination*: if a folder of that
  name is already at the new root and is **not** ours, the move is abandoned rather than
  overwriting it, and that session's `exportFolderName` is cleared so the trailing backfill
  re-exports it under a fresh deduped name. The archive still ends up complete, and nothing
  of the user's is deleted.
- **Root identity is compared canonically**, via `resolvingSymlinksInPath().standardizedFileURL`
  — in the Browse… guard and again in `relocateAll`. An `NSOpenPanel` can hand back `/tmp/x`
  for a root resolved as `/private/tmp/x`. With raw `URL` equality those read as *different*
  directories, and every folder would be passed to "clear the destination, then move the
  source onto it" with destination == source: the whole archive deleted.
- **An in-flight backfill is drained first.** The launch backfill is still resolving
  collisions against, and writing into, the root about to be emptied.

### Backfill re-entrancy

`backfillMissing` has two triggers that can overlap: the main window's `.task` — which
re-runs whenever the window is recreated, a normal flow since the `MenuBarExtra` keeps the
app alive — and `relocate`. Two concurrent runs would each fetch the same not-yet-reached
sessions, lose the `fileExists` race against each other, and write half the library twice
(`…-standup/` **and** `…-standup-2/`), with the row pointing at only one. The other is then
unreachable: no rename touches it and no delete removes it.

So the runs are serialized on a stored `Task`, and a late caller **joins** it rather than
early-returning — `relocate`'s caller drops the Settings spinner the moment it returns, so
returning early would report "done" while sessions were still unwritten.

The same fetch-then-iterate shape opens a second hole: a session deleted on the main context
mid-backfill is still in the background context's array. Both interleavings are covered by a
`deletedIDs` set — checked before each write (delete first), and again over the assigned
names once the run finishes (export first, so the delete saw a still-nil `exportFolderName`
and removed nothing). Without it, deleting a session during the first-run backfill leaves a
full transcript of it, plus a copy of its audio, in the user's folder permanently.

## Known deferrals

- **No progress detail during a relocate.** A large library with mirrored audio shows a
  spinner and "Moving your existing sessions…", not a count. Browse… is disabled while it
  runs so a second pick can't race the first.
- **A manually deleted folder is not restored** until the session is next mutated.
  `exportFolderName` is still set, so the backfill skips it. Recreating it would need a
  per-session `fileExists` sweep at launch, which was judged not worth the launch cost.
- **Files are one-way.** Editing `transcript.md` in another app does not flow back, and the
  next export overwrites it. Making disk writable would mean conflict resolution against a
  live SwiftData store, which is a different feature.
- **No "use the default folder again" affordance.** Once the user has browsed somewhere,
  the only way back to the container is to browse to it, which is impractical. Adding a
  Reset would be a few lines if anyone asks.
- **Only the last-chosen folder is bookmarked.** A relocate away from a user-chosen root
  drops the old bookmark, so folders left behind by a failed move are no longer reachable
  by the app (they are still perfectly reachable by the user).
- **No localization** — headings are hardcoded English, like `PDFExporter` and
  `MarkdownFormatter` before it.

## Files

**New**
- `OpenCaptions/Services/Export/ExportRoot.swift` — the destination as a value type, and
  the access bracket every write goes through.
- `OpenCaptions/Services/Export/MarkdownExportLocation.swift` — bookmark persistence, the
  in-container default, the Browse… panel.
- `OpenCaptions/Services/Export/ExportFolderName.swift` — slugify + collision resolution.
- `OpenCaptions/Services/Export/SessionExportSnapshot.swift` — the `Sendable` payload.
- `OpenCaptions/Services/Export/SessionMarkdownWriter.swift` — the actor; the only file
  that touches disk.
- `OpenCaptions/Services/Export/SessionExportCoordinator.swift` — the call-site façade,
  folder-name bookkeeping, backfill, relocate.
- `OpenCaptions/Utility/Formatting/MarkdownFormatter+Summary.swift` — `summary.md`.
- `OpenCaptions/Views/Settings/MacMarkdownExportSection.swift` — the Settings row.

**Edited**
- `OpenCaptions/Model/TranscriptionSession.swift` — `exportFolderName`.
- `OpenCaptions/Utility/Formatting/MarkdownFormatter.swift` — shared `header` /
  `summarySections` / `sortedLines` lifted out of `formatSession` (whose output is
  unchanged) and `formatTranscript` added. `header` and `summarySections` had to lose
  `private`: `+Summary` is a separate file, and Swift's `private` doesn't reach across
  files even for extensions of the same type.
- `OpenCaptions/OpenCaptions.entitlements` — `files.bookmarks.app-scope`.
- `OpenCaptions/OpenCaptionsApp.swift` — the launch backfill.
- The seven mutation sites in the table above.

## Verification

There is no test target, and per the project's workflow the build is run in Xcode. Static
checks done here: `xcrun swiftc -parse` clean on every new and edited Swift file, and
`plutil -lint` clean on the entitlements.

Manual checklist:

1. Record a session → a dated folder with `transcript.md` appears under Settings' folder.
2. Let the summary land → `summary.md` appears **and the folder is renamed** to the
   AI-generated title.
3. Re-transcribe that session → `summary.md` disappears, then comes back when the summary
   regenerates.
4. Rename a speaker (Edit Speakers) → labels update in `transcript.md`.
5. Tick an action item → `- [ ]` becomes `- [x]` in `summary.md`.
6. Delete the session → the whole folder goes.
7. Settings → General → Markdown Export → **Browse…** to `~/Documents/Open Captions` →
   every existing folder moves there, and the old location is left empty.
8. Quit and relaunch → the chosen folder is still in effect (the bookmark resolved) and new
   sessions still write there.
9. Rename the chosen folder in Finder, relaunch → the stale bookmark re-resolves and
   exports continue.
10. Delete the chosen folder entirely, relaunch → the app falls back to its own container
    and keeps exporting rather than failing.
11. Import an audio file with "Save session audio" **off** → the folder has markdown but no
    `audio.m4a`.
12. Two sessions on the same day with the same title → the second gets a `-2` folder.
13. Fresh install with pre-existing sessions (or delete the bookmark key) → the launch
    backfill writes the whole library.
14. Copy as Markdown still produces exactly what it did before (the `formatSession` refactor
    is output-neutral).
