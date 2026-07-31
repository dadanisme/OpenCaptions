//
//  MarkdownExportLocation.swift
//  OpenCaptions
//
//  Where the markdown export writes, and how that choice survives relaunch under
//  App Sandbox.
//
//  A path string would be useless here: `com.apple.security.files.user-selected.read-write`
//  grants access to a folder for the lifetime of the Powerbox grant, not forever, so
//  a remembered path stops being writable on the next launch. What IS durable is an
//  app-scoped SECURITY-SCOPED BOOKMARK (hence `com.apple.security.files.bookmarks.app-scope`
//  in the entitlements), resolved back to a URL at launch and bracketed around every
//  write — see `ExportRoot.withAccess`.
//
//  Until the user picks a folder the root is the app's OWN container Documents
//  directory, which needs no grant at all. Export is therefore always on and never
//  blocked on a prompt; Browse… only moves it somewhere the user can reach easily.
//  See docs/2026-07-31-macos-markdown-export.md.
//

import AppKit
import Foundation
import SwiftData

@MainActor
@Observable
final class MarkdownExportLocation {
    static let shared = MarkdownExportLocation()

    /// UserDefaults key holding the app-scoped security-scoped bookmark (`Data`).
    /// Deliberately NOT in `register(defaults:)` — a bookmark blob has no sensible
    /// registered default, and its ABSENCE is what means "still on the default
    /// in-container location". Same reasoning as `vocabularyTermsKey`.
    static let bookmarkKey = "opencaptions.markdownExport.bookmark"

    /// Folder created inside the container when no destination has been chosen.
    private static let defaultFolderName = "Open Captions"

    /// The current destination. Observable, so the Settings row re-renders the
    /// moment Browse… lands.
    private(set) var root: ExportRoot

    /// True while a relocate is in flight, so Settings can disable Browse… rather
    /// than let a second pick race the first.
    private(set) var isRelocating = false

    private init() {
        root = Self.resolveStoredRoot() ?? Self.defaultRoot
    }

    // MARK: - Derived

    /// Whether exports are still going to the in-container fallback.
    var isDefaultLocation: Bool { !root.isSecurityScoped }

    // MARK: - Choosing

    /// Presents a directory picker and, on confirmation, moves every existing
    /// export to the new destination.
    /// - Parameter container: used only to export sessions that had never been
    ///   written yet. Optional because Settings can be opened before the main
    ///   window has handed `LiveSessionStore` the shared container; the move itself
    ///   never needs it.
    func chooseFolder(container: ModelContainer?) async {
        guard !isRelocating else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder Open Captions writes session transcripts into."
        panel.directoryURL = root.url

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // Canonical comparison, not `URL` equality: the panel can hand back
        // `/tmp/x` for a root already resolved to `/private/tmp/x`, and treating
        // those as different folders would send the archive through a
        // move-onto-itself. See `ExportRoot.canonicalPath`.
        let candidate = ExportRoot(url: chosen, isSecurityScoped: true)
        guard candidate.canonicalPath != root.canonicalPath else { return }

        // The bookmark must be minted while the Powerbox grant from the panel is
        // still live — do it before anything else touches the URL.
        guard let bookmark = try? chosen.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else {
            print("⚠️ Markdown export: could not bookmark \(chosen.path) — keeping the current folder")
            NSSound.beep()
            return
        }

        let previous = root
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        root = candidate

        isRelocating = true
        await SessionExportCoordinator.relocate(from: previous, to: root, container: container)
        isRelocating = false
    }

    /// Opens the export folder in Finder, creating it first if it doesn't exist yet
    /// (it won't until the first session is exported).
    func revealInFinder() {
        root.withAccess { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Resolution

    /// The in-container fallback: `<container>/Documents/Open Captions`. Chosen
    /// over Application Support because these are user-readable documents, not app
    /// state — and it mirrors the `~/Documents/Open Captions` layout a user gets
    /// once they Browse… somewhere real.
    private static var defaultRoot: ExportRoot {
        let base = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return ExportRoot(
            url: base.appendingPathComponent(defaultFolderName, isDirectory: true),
            isSecurityScoped: false)
    }

    /// Resolves the stored bookmark, refreshing it when macOS reports it stale (the
    /// folder was renamed or moved). Returns nil — falling the app back to the
    /// default — when the bookmark can't be resolved at all, e.g. the folder was
    /// deleted or lives on a volume that isn't mounted.
    private static func resolveStoredRoot() -> ExportRoot? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        else {
            print("⚠️ Markdown export: stored folder is unreachable — falling back to the app's own folder")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }

        let root = ExportRoot(url: url, isSecurityScoped: true)
        if isStale {
            // Re-minting needs the scope held; `withAccess` provides it.
            root.withAccess { scoped in
                if let refreshed = try? scoped.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
                }
            }
        }
        return root
    }
}
