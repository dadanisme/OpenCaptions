//
//  SessionExportCoordinator.swift
//  OpenCaptions
//
//  The façade every mutation site calls: "this session changed, mirror it".
//
//  It owns the FOLDER-NAME bookkeeping — deriving the name, resolving collisions,
//  and stamping `TranscriptionSession.exportFolderName` — then hands a `Sendable`
//  snapshot to `SessionMarkdownWriter` for the actual disk work. Splitting it this
//  way keeps the SwiftData write on the actor that owns the model while the I/O
//  runs elsewhere. Nothing here is throwing or awaited by a save path: an export
//  must never be able to fail a session save.
//
//  A session's export root is no longer always the one shared default: a session
//  filed under a `Workspace` with its own folder resolves there instead (see
//  `resolvedRoot`). Every root-keyed piece of bookkeeping below (`claimed`,
//  `existingFolderNames`) is therefore keyed by the ROOT's canonical path, not
//  assumed singular.
//  See docs/2026-07-31-macos-markdown-export.md and docs/2026-08-06-macos-workspaces.md.
//

import Foundation
import SwiftData

@MainActor
enum SessionExportCoordinator {

    /// Folder names handed out this run whose directories may not exist yet — the
    /// writer is asynchronous, so `fileExists` alone can't stop two sessions saved
    /// back-to-back with the same day and title from claiming one name. Only grows;
    /// it is bounded by the number of sessions touched in a single app run. Keyed by
    /// the destination root's canonical path, so the same name in two different
    /// roots (a workspace folder vs. the default, or two workspace folders) is
    /// never treated as a collision.
    private static var claimed: [String: Set<String>] = [:]

    /// Sessions deleted during this run. A backfill iterates a snapshot fetched on
    /// its OWN context, so a row deleted on the main context afterwards is still in
    /// its array — it would happily write a folder for a session that no longer
    /// exists, which no rename could then fix and no delete would ever remove.
    /// Checked before each backfill write, and again after, in case the export won
    /// the race and the delete found `exportFolderName` still nil.
    private static var deletedIDs: Set<PersistentIdentifier> = []

    /// The backfill in flight, if any. `backfillMissing` has two triggers that can
    /// overlap — the main window's `.task`, which re-runs whenever the window is
    /// recreated, and `relocate` after a Browse… — and a second run would fetch the
    /// same not-yet-reached sessions, lose the `fileExists` race, and write every
    /// one of them a second time as `-2`.
    private static var backfillTask: Task<Void, Never>?

    // MARK: - Root resolution

    /// The root `session` should export to: its workspace's own folder when it has
    /// one and that workspace has a custom folder configured, otherwise `fallback`
    /// (the caller's already-resolved `MarkdownExportLocation.shared.root`).
    ///
    /// `nonisolated` and takes `fallback` explicitly (rather than reading
    /// `MarkdownExportLocation.shared` itself) so it can be called from the
    /// backfill's detached, off-main-actor closure — see `existingFolderNames`.
    private nonisolated static func resolvedRoot(for session: TranscriptionSession, fallback: ExportRoot) -> ExportRoot {
        session.workspace?.resolvedExportRoot() ?? fallback
    }

    private static func claimedNames(in root: ExportRoot) -> Set<String> {
        claimed[root.canonicalPath] ?? []
    }

    private static func claim(_ name: String, in root: ExportRoot) {
        claimed[root.canonicalPath, default: []].insert(name)
    }

    private static func unclaim(_ name: String, in root: ExportRoot) {
        claimed[root.canonicalPath]?.remove(name)
    }

    // MARK: - Export

    /// Mirrors `session` to disk, renaming its folder first if the title changed.
    ///
    /// Fire-and-forget: the folder-name stamp is committed synchronously (so a
    /// delete arriving a moment later knows what to clean up) and the files are
    /// written on `SessionMarkdownWriter`.
    static func export(_ session: TranscriptionSession, context: ModelContext) {
        let root = resolvedRoot(for: session, fallback: MarkdownExportLocation.shared.root)
        let previous = session.exportFolderName
        let desired = ExportFolderName.make(date: session.sessionDate, title: session.sessionTitle)

        // Always re-resolve rather than short-circuiting on "the old name starts with
        // the new one". A session deduped to `-2` keeps its folder anyway, because
        // the un-suffixed name is still taken by the neighbour that owns it and the
        // loop lands back on the current name. A `hasPrefix` fast path instead
        // silently swallows the retitles that SHORTEN a title ("Client call with
        // Acme" → "Client call"), which are exactly the ones that must rename.
        let resolved = ExportFolderName.resolveCollision(
            desired, in: root, keeping: previous, claimed: claimedNames(in: root))
        claim(resolved, in: root)

        if previous != resolved {
            session.exportFolderName = resolved
            try? context.save()
        }

        let snapshot = SessionExportSnapshot(
            session: session, folderName: resolved, previousFolderName: previous)
        Task { await SessionMarkdownWriter.shared.write(snapshot, to: root) }
    }

    // MARK: - Delete

    /// Records that `sessions` are being deleted and removes their exported folders.
    ///
    /// Call this BEFORE `context.delete(_:)` — it needs to read `exportFolderName`,
    /// `workspace`, and the persistent id off rows that still exist. The folder
    /// removal itself is asynchronous, so it lands after the SwiftData commit either
    /// way. Sessions may resolve to different roots (different workspaces, or a mix
    /// of workspace and default), so they're grouped by root before removal.
    static func remove(_ sessions: [TranscriptionSession]) {
        guard !sessions.isEmpty else { return }
        deletedIDs.formUnion(sessions.map(\.persistentModelID))

        let fallback = MarkdownExportLocation.shared.root
        var rootsByPath: [String: ExportRoot] = [:]
        var namesByPath: [String: [String]] = [:]
        for session in sessions {
            guard let name = session.exportFolderName, !name.isEmpty else { continue }
            let root = resolvedRoot(for: session, fallback: fallback)
            rootsByPath[root.canonicalPath] = root
            namesByPath[root.canonicalPath, default: []].append(name)
        }
        for (path, names) in namesByPath {
            guard let root = rootsByPath[path] else { continue }
            names.forEach { unclaim($0, in: root) }
            Task { await SessionMarkdownWriter.shared.remove(folderNames: names, from: root) }
        }
    }

    // MARK: - Workspace assignment

    /// Moves `session` to `workspace` (or back to the default location when nil),
    /// relocating its already-exported folder to the new root if it has one. The
    /// single write path a "assign this session to a workspace" UI action calls,
    /// mirroring `SpeakerRenamer.apply` as the single write path for a rename.
    static func reassignWorkspace(_ session: TranscriptionSession, to workspace: Workspace?, context: ModelContext) {
        let fallback = MarkdownExportLocation.shared.root
        let old = resolvedRoot(for: session, fallback: fallback)
        session.workspace = workspace
        try? context.save()
        let new = resolvedRoot(for: session, fallback: fallback)

        guard old.canonicalPath != new.canonicalPath, let name = session.exportFolderName else { return }
        unclaim(name, in: old)
        Task {
            if await SessionMarkdownWriter.shared.relocateOne(folderName: name, from: old, to: new) {
                claim(name, in: new)
            } else {
                // Couldn't move (a same-named folder not written by this app already
                // sits at the destination) — clear the stamp so the next export
                // writes a fresh, deduped name into the new root instead of leaving
                // this session's transcript stranded in the old one.
                session.exportFolderName = nil
                try? context.save()
                export(session, context: context)
            }
        }
    }

    /// Moves every session in `workspace` from `old` to `new`, one folder at a
    /// time. Never bulk-moves the whole root (`SessionMarkdownWriter.relocateAll`)
    /// — when a workspace has never had a custom folder, `old` IS the shared
    /// default, which other sessions and other workspaces may also be using; a
    /// bulk move would steal folders that aren't this workspace's to move.
    static func changeWorkspaceFolder(_ workspace: Workspace, from old: ExportRoot, to new: ExportRoot) async {
        guard old.canonicalPath != new.canonicalPath else { return }
        for session in workspace.sessions {
            guard let name = session.exportFolderName else { continue }
            unclaim(name, in: old)
            if await SessionMarkdownWriter.shared.relocateOne(folderName: name, from: old, to: new) {
                claim(name, in: new)
            } else if let context = session.modelContext {
                session.exportFolderName = nil
                try? context.save()
                export(session, context: context)
            }
        }
    }

    /// Deletes `workspace`, first moving every session filed under it back to the
    /// default export location. The `.nullify` delete rule clears each affected
    /// session's `workspace` relationship automatically, but the FILES live outside
    /// SwiftData and need this explicit move.
    static func deleteWorkspace(_ workspace: Workspace, context: ModelContext) async {
        let old = workspace.resolvedExportRoot() ?? MarkdownExportLocation.shared.root
        let new = MarkdownExportLocation.shared.root
        // Clear the bookmark BEFORE moving files, not after: if a session's move
        // fails, `changeWorkspaceFolder`'s fallback re-exports it via `export`,
        // which resolves the root through `session.workspace?.resolvedExportRoot()`
        // — still this same workspace object until the row is actually deleted
        // below. Leaving the bookmark set would resolve that fallback back to
        // `old`, stranding the transcript in the very folder being abandoned.
        workspace.exportBookmark = nil
        await changeWorkspaceFolder(workspace, from: old, to: new)
        context.delete(workspace)
        try? context.save()
    }

    // MARK: - Backfill

    /// Exports every session that has never been exported.
    ///
    /// On the first launch after this feature ships that is the entire library —
    /// the one-time backfill. Afterwards it is a cheap no-result fetch, and it
    /// self-heals a session whose export was interrupted. Runs entirely on a
    /// background context (rendering a few hundred transcripts on the main actor
    /// would visibly stall launch).
    /// Serialized: a caller arriving while a backfill is running JOINS it rather
    /// than starting a rival. Joining (not early-returning) matters for `relocate`,
    /// whose caller drops the Settings spinner the moment it returns.
    static func backfillMissing(container: ModelContainer) async {
        if let existing = backfillTask {
            await existing.value
            return
        }
        // The task clears the slot itself, as its own last step, so a caller
        // arriving after it finished starts a fresh run instead of joining a dead
        // one. The assignment below cannot lose the race: `Task {}` created on the
        // main actor doesn't begin until this function suspends, which is the
        // `await` two lines down.
        let task = Task {
            await runBackfill(container: container)
            backfillTask = nil
        }
        backfillTask = task
        await task.value
    }

    private static func runBackfill(container: ModelContainer) async {
        let fallback = MarkdownExportLocation.shared.root
        let reserved = claimed
        let exported = await Task.detached(priority: .utility) { () async -> [(id: PersistentIdentifier, name: String, root: ExportRoot)] in
            let context = ModelContext(container)
            // Seeded lazily per root the first time a session resolves to it —
            // reserved (in-memory) names for that root, unioned with whatever
            // SwiftData already has on record for it — then grown in place as
            // more sessions in this same root are assigned names below.
            var takenByPath: [String: Set<String>] = [:]

            let descriptor = FetchDescriptor<TranscriptionSession>(
                predicate: #Predicate { $0.exportFolderName == nil })
            guard let sessions = try? context.fetch(descriptor), !sessions.isEmpty else { return [] }

            var assigned: [(id: PersistentIdentifier, name: String, root: ExportRoot)] = []
            for session in sessions {
                // This array was fetched before the loop began; a row deleted on the
                // main context since then is still in it, and writing its folder
                // would strand a transcript of a session the user deleted.
                let id = session.persistentModelID
                if await isDeleted(id) { continue }

                let root = resolvedRoot(for: session, fallback: fallback)
                var taken = takenByPath[root.canonicalPath]
                    ?? (reserved[root.canonicalPath] ?? []).union(
                        existingFolderNames(in: context, root: root, fallback: fallback))

                let desired = ExportFolderName.make(
                    date: session.sessionDate, title: session.sessionTitle)
                let name = ExportFolderName.resolveCollision(
                    desired, in: root, keeping: nil, claimed: taken)
                taken.insert(name)
                takenByPath[root.canonicalPath] = taken
                assigned.append((id: id, name: name, root: root))

                // Commit the name BEFORE the folder exists. Batching the saves to
                // the end would mean a quit mid-backfill leaves folders on disk that
                // no row claims — the next launch would see them as collisions and
                // write every session again as `-2`.
                session.exportFolderName = name
                try? context.save()

                let snapshot = SessionExportSnapshot(
                    session: session, folderName: name, previousFolderName: nil)
                await SessionMarkdownWriter.shared.write(snapshot, to: root)
            }
            return assigned
        }.value

        // Second half of the same guard, for the opposite interleaving: the export
        // won the race and the delete read a still-nil `exportFolderName`, so it
        // removed nothing. Now that the name is known, clean up — grouped by root,
        // since `exported` may span several workspaces' folders.
        var rootsByPath: [String: ExportRoot] = [:]
        var strandedByPath: [String: [String]] = [:]
        for entry in exported {
            rootsByPath[entry.root.canonicalPath] = entry.root
            if deletedIDs.contains(entry.id) {
                strandedByPath[entry.root.canonicalPath, default: []].append(entry.name)
            } else {
                claim(entry.name, in: entry.root)
            }
        }
        for (path, names) in strandedByPath {
            guard let root = rootsByPath[path] else { continue }
            Task { await SessionMarkdownWriter.shared.remove(folderNames: names, from: root) }
        }
    }

    /// Whether a session was deleted during this run. `nonisolated` wrapper so the
    /// detached backfill can consult the main actor's set.
    private nonisolated static func isDeleted(_ id: PersistentIdentifier) async -> Bool {
        await MainActor.run { deletedIDs.contains(id) }
    }

    // MARK: - Relocate

    /// Moves every exported folder to a newly chosen root — the single shared
    /// default location changing (Settings → Browse…). NOT used for a workspace's
    /// own folder changing; see `changeWorkspaceFolder`, which never bulk-moves a
    /// root other sessions/workspaces might also be using.
    ///
    /// Folder names are preserved, so every session's stored `exportFolderName`
    /// stays valid and the move itself needs no SwiftData write. The container is
    /// optional only because Settings can be opened without the main window (which
    /// is what hands `LiveSessionStore` the container).
    static func relocate(from old: ExportRoot, to new: ExportRoot, container: ModelContainer?) async {
        // Drain any launch backfill first: it is still resolving collisions against
        // — and writing into — the root we are about to empty.
        if let container, backfillTask != nil { await backfillMissing(container: container) }

        let failed = Set(await SessionMarkdownWriter.shared.relocateAll(from: old, to: new))
        guard let container else { return }

        // A folder that couldn't move (a same-named folder of the user's already at
        // the destination, or a failed cross-volume move) is left where it is rather
        // than destroying anything. Forgetting its name hands the session to the
        // backfill below, which re-exports it into the new root under a fresh,
        // deduped name — so the archive is complete either way.
        if !failed.isEmpty {
            await Task.detached(priority: .utility) {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<TranscriptionSession>(
                    predicate: #Predicate { $0.exportFolderName != nil })
                guard let sessions = try? context.fetch(descriptor) else { return }
                for session in sessions where failed.contains(session.exportFolderName ?? "") {
                    session.exportFolderName = nil
                }
                try? context.save()
            }.value
        }

        // Sessions that had never been exported have nothing to move — write them
        // now, so the folder the user just chose is the complete archive.
        await backfillMissing(container: container)
    }

    /// Folder names already spoken for **in `root`**, so a backfill can't hand one
    /// out twice within that same root — a name already used in a different root
    /// (a different workspace's folder, or the default) is no collision at all.
    /// `nonisolated` so the detached bulk paths can call it on their own context;
    /// takes `fallback` explicitly rather than reading `MarkdownExportLocation`
    /// directly, which is MainActor-isolated and unreachable from here.
    private nonisolated static func existingFolderNames(
        in context: ModelContext, root: ExportRoot, fallback: ExportRoot
    ) -> Set<String> {
        let descriptor = FetchDescriptor<TranscriptionSession>(
            predicate: #Predicate { $0.exportFolderName != nil })
        guard let sessions = try? context.fetch(descriptor) else { return [] }
        return Set(
            sessions
                .filter { resolvedRoot(for: $0, fallback: fallback).canonicalPath == root.canonicalPath }
                .compactMap(\.exportFolderName))
    }
}
