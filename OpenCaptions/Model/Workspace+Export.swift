//
//  Workspace+Export.swift
//  OpenCaptions
//
//  A workspace's own export root: resolving its stored bookmark, and the
//  Choose/Change/Clear/Reveal folder actions the Workspaces screen offers.
//  Mirrors `MarkdownExportLocation`'s picker + bookmark handling, scoped to one
//  workspace's own bookmark instead of the single shared one.
//

import AppKit
import Foundation
import SwiftData

extension Workspace {

    /// This workspace's own root, or nil to mean "use the app-wide default"
    /// (`MarkdownExportLocation.shared.root`).
    ///
    /// Mirrors `MarkdownExportLocation.resolveStoredRoot()`: refreshes and
    /// persists a stale bookmark, and clears + persists nil when the bookmark
    /// can't be resolved at all (the folder was deleted, or its volume isn't
    /// mounted) so a dead bookmark isn't retried forever.
    func resolvedExportRoot() -> ExportRoot? {
        // Bound to a differently-named local, not `exportBookmark` itself — a
        // `guard let exportBookmark` would shadow the property with an immutable
        // local for the rest of this scope, and the writes below need the setter.
        guard let bookmark = exportBookmark else { return nil }

        var refreshed: Data?
        guard let root = SecurityScopedBookmark.resolve(bookmark, onRefresh: { refreshed = $0 })
        else {
            exportBookmark = nil
            try? modelContext?.save()
            return nil
        }
        if let refreshed {
            exportBookmark = refreshed
            try? modelContext?.save()
        }
        return root
    }

    /// A read-only peek at this workspace's own root, for display purposes.
    /// Resolves the bookmark without persisting a stale-bookmark refresh or a
    /// dead-bookmark clear, unlike `resolvedExportRoot()` — safe to call from a
    /// SwiftUI view body, which must never mutate `@Model` state as a side
    /// effect of rendering.
    func displayExportRoot() -> ExportRoot? {
        guard let bookmark = exportBookmark else { return nil }
        return SecurityScopedBookmark.resolve(bookmark, onRefresh: { _ in })
    }

    /// Presents a directory picker and, on confirmation, moves this workspace's
    /// sessions to the new destination.
    @MainActor
    func chooseExportFolder() async {
        let old = resolvedExportRoot() ?? MarkdownExportLocation.shared.root

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder sessions in “\(name)” export into."
        panel.directoryURL = old.url

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // Canonical comparison, not `URL` equality — see `ExportRoot.canonicalPath`.
        let candidate = ExportRoot(url: chosen, isSecurityScoped: true)
        guard candidate.canonicalPath != old.canonicalPath else { return }

        // The bookmark must be minted while the Powerbox grant from the panel is
        // still live — do it before anything else touches the URL.
        guard let bookmark = SecurityScopedBookmark.mint(for: chosen) else {
            print("⚠️ Workspace export: could not bookmark \(chosen.path) — keeping the current folder")
            NSSound.beep()
            return
        }

        exportBookmark = bookmark
        try? modelContext?.save()
        await SessionExportCoordinator.changeWorkspaceFolder(self, from: old, to: candidate)
    }

    /// Drops this workspace's custom folder and moves its sessions back to the
    /// app-wide default.
    @MainActor
    func clearExportFolder() async {
        guard exportBookmark != nil else { return }
        let old = resolvedExportRoot() ?? MarkdownExportLocation.shared.root
        exportBookmark = nil
        try? modelContext?.save()
        await SessionExportCoordinator.changeWorkspaceFolder(self, from: old, to: MarkdownExportLocation.shared.root)
    }

    /// Opens this workspace's export folder in Finder.
    @MainActor
    func revealExportFolder() {
        (resolvedExportRoot() ?? MarkdownExportLocation.shared.root).withAccess { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
