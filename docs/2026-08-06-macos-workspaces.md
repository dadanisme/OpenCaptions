# macOS Workspaces

**Date:** 2026-08-06 · **Scope:** Open Captions (native macOS) only · **Issue:** [#24](https://github.com/dadanisme/OpenCaptions/issues/24)

Every session used to export to one flat root (`MarkdownExportLocation`, see
`2026-07-31-macos-markdown-export.md`), so work meetings, personal calls, and
one-off recordings interleaved in the same folder tree with nothing separating
them. A work transcript folder needs to be *only* work — so it can live on a
work drive or be synced by a work-managed cloud account — and before this the
only way to get that was to not record personal sessions in the app at all.

`Workspace` is a new SwiftData `@Model`: a named container a session can be
filed under, assignable from the session list and the detail toolbar, filtered
from the Transcriptions toolbar, and managed from its own sidebar section. Each
workspace can optionally be given its own export folder; a session with no
workspace, or one whose workspace has no custom folder, uses the existing
shared default.

## "Tag" became "Workspace", and it's one per session

Issue #24 proposed a many-to-many `Tag` model and left an explicit open
decision: what happens when a session carries several tags that each define a
folder? That question doesn't have a satisfying answer — first-match-in-order,
a designated "primary" tag, and write-to-every-folder were all considered, and
all of them added real UI or duplication cost for a case that's arguably not
even a sensible thing to want.

The decision made here sidesteps it entirely: **a session belongs to at most
one workspace.** `TranscriptionSession.workspace` is a plain to-one
relationship, not a join table, so a session's export root is never ambiguous:

```swift
session.workspace?.resolvedExportRoot() ?? MarkdownExportLocation.shared.root
```

The rename from "Tag" to "Workspace" follows from the same shift: this isn't a
label a session can wear several of, it's a single container a session lives
in — closer to "which environment is this session part of" than "what is this
session about".

## The relationship: `.nullify`, not `.cascade`

```swift
@Model
final class Workspace {
    var name: String
    var createdAt: Date
    var userId: String?
    var exportBookmark: Data?

    @Relationship(deleteRule: .nullify)
    var sessions: [TranscriptionSession] = []
}
```

Every other to-many relationship in this codebase (`TranscriptionSession.lines`,
`.actionItems`) cascades: the child only exists because of the parent, so
deleting the parent deletes the children. A workspace is the opposite kind of
relationship — sessions exist independently and are merely *filed under* it —
so deleting a workspace must never delete the sessions in it. `.nullify` clears
`session.workspace` on every affected row instead, and `deleteWorkspace` (below)
does the matching thing to their exported *files*, which SwiftData's delete
rule has no way to reach.

`Workspace.userId` mirrors `TranscriptionSession.userId`: a workspace is
per-account data, scoped and queried the same way sessions are, not a
device-local preference like `VocabularyStore`.

## Why per-root state (`claimed`, `existingFolderNames`) had to become root-keyed

Before this, `SessionExportCoordinator` only ever dealt with one shared root, so
its in-memory collision guard (`claimed: Set<String>`, protecting against two
sessions racing to the same day+title before either folder exists on disk) and
its backfill seed (`existingFolderNames`, everything SwiftData already has on
record) could both be flat sets. With per-workspace roots, a folder name used
in workspace A's folder is not a collision with the same name in workspace B's
folder or the default — so both became keyed by the destination root's
canonical path (`[String: Set<String>]`), and every read/write site
(`export`, `remove`, `runBackfill`) resolves each session's own root before
touching them.

## Why a workspace's folder change never bulk-moves a root

`SessionMarkdownWriter.relocateAll` bulk-moves every export-owned folder found
under a root — correct for the single shared default changing in Settings,
because that really is the one root everything was using. It is **not** safe
to reuse for a workspace's own folder change: a workspace that has never had a
custom folder resolves to the shared default as its "old" root, and that root
may hold other workspaces' sessions and plain unassigned sessions too. Bulk-
moving everything out of it would steal folders that were never this
workspace's to move.

So workspace-scoped moves (`SessionExportCoordinator.changeWorkspaceFolder`)
always go one session at a time, via a new `SessionMarkdownWriter.relocateOne`
— the same ownership test (`transcript.md` inside → ours to move) and
same-name-at-destination guard `relocateAll` uses, just for one named folder
instead of a whole directory listing. `relocateAll` is now written as a loop
over the same shared `moveIfOurs` helper, so the two guards can't drift apart.

This same per-session path is what `reassignWorkspace` uses for a single
session moving between workspaces, and what `deleteWorkspace` uses to move
every session in a deleted workspace back to the default before the row itself
is removed.

## Assignment is inline, not a sheet

Every other multi-value association in this app (`Edit Speakers…`) is a sheet,
because renaming several speakers at once needs several text fields. Assigning
a workspace is single-select — a session has at most one — so it's a plain
`Menu("Workspace") { ... }` with a checkmark on the current selection, in both
the session list's context menu and the detail toolbar's overflow menu.
`SessionExportCoordinator.reassignWorkspace` is the single write path both call,
mirroring `SpeakerRenamer.apply` as the single write path for a rename.

## Filtering lives in two places

The Transcriptions toolbar gets an All / Unassigned / *workspace* filter menu,
narrowing the same `@Query` result in Swift — the same "fetch the user-scoped
sessions, then filter by relationship content in Swift" pattern
`ActionItemsScreen`/`KeyPointsScreen` already use, since a `#Predicate` over a
to-one relationship's identity isn't worth fighting SwiftData for here.

The `Workspaces` sidebar section, by contrast, is a pure manager — create,
rename, delete, and set a workspace's folder — the same reason Vocabulary is a
sidebar section rather than a Settings pane (a variable-length list editor
doesn't fit the fixed Settings window). It does not also render a filtered
session list; that would just duplicate the Transcriptions toolbar filter.

## Known deferrals

- **No reordering or color-coding of workspaces.** The list sorts by name.
  Nothing in the issue asked for either.
- **A workspace pointed at a folder another workspace also uses** isn't
  guarded against. Both would then legitimately claim folders inside it
  (`isExportFolder`'s ownership test doesn't distinguish *which* workspace
  wrote a folder, only that this app did), which is a user misconfiguration,
  not a correctness bug — nothing is silently overwritten because the same
  same-name-at-destination guard from `relocateAll` still applies.
- **No localization**, matching every other user-facing string in the app.

## Files

**New**
- `OpenCaptions/Model/Workspace.swift` — the model.
- `OpenCaptions/Model/Workspace+Export.swift` — `resolvedExportRoot`, Choose/
  Change/Clear/Reveal folder actions.
- `OpenCaptions/Services/Export/SecurityScopedBookmark.swift` — mint/resolve,
  pulled out of `MarkdownExportLocation` so a workspace's own bookmark reuses
  the exact same stale/dead-bookmark handling.
- `OpenCaptions/Views/Workspaces/WorkspacesScreen.swift` — the sidebar manager.
- `OpenCaptions/Views/Workspaces/WorkspaceRenameSheet.swift`.

**Edited**
- `OpenCaptions/Model/TranscriptionSession.swift` — the `workspace` relationship.
- `OpenCaptions/OpenCaptionsApp.swift` — `Workspace.self` in the schema.
- `OpenCaptions/ContentView.swift` — the `workspaces` `NavSection` case.
- `OpenCaptions/Services/Export/SessionExportCoordinator.swift` — root-keyed
  `claimed`/`existingFolderNames`, per-session root resolution in `export` and
  `runBackfill`, `reassignWorkspace`, `changeWorkspaceFolder`, `deleteWorkspace`.
- `OpenCaptions/Services/Export/SessionMarkdownWriter.swift` — `relocateOne`,
  and `relocateAll` refactored onto the same `moveIfOurs` helper.
- `OpenCaptions/Services/Export/MarkdownExportLocation.swift` — refactored onto
  `SecurityScopedBookmark`; no behavior change.
- `OpenCaptions/Views/Shell/TranscriptionsScreen.swift` — the filter menu, the
  row's `Workspace` submenu.
- `OpenCaptions/Views/SessionDetail/MacSessionDetailView.swift` — the same
  `Workspace` submenu in the overflow toolbar menu.

## Verification

No test target; the build is run in Xcode per the project's workflow. Manual
checklist:

1. Create two workspaces, assign a few sessions to each from both the list
   context menu and the detail toolbar — the checkmark tracks correctly in
   both places.
2. Give one workspace a custom folder (Choose Export Folder…) — only that
   workspace's sessions move there; unrelated sessions and other workspaces'
   folders still in the shared default are untouched.
3. Reassign a session between two workspaces that each have a custom folder —
   its folder physically moves and `exportFolderName` is preserved.
4. Clear a workspace's custom folder, and separately delete a workspace that
   has one — its sessions' folders move back to the default root either way.
5. Use the Transcriptions toolbar filter (All / Unassigned / a workspace) and
   confirm the list narrows correctly.
6. Quit and relaunch — a workspace's custom folder is still remembered (the
   bookmark resolved) and still in effect.
