//
//  SecurityScopedBookmark.swift
//  OpenCaptions
//
//  Minting and resolving app-scoped security-scoped bookmarks — the durable
//  reference to a user-chosen folder that survives relaunch under App Sandbox
//  (see `MarkdownExportLocation`'s header comment for why a path string alone
//  can't do this). Shared by the single global export root and by any number of
//  per-`Workspace` export roots, so the stale/dead-bookmark handling only has
//  to be gotten right once.
//

import Foundation

enum SecurityScopedBookmark {

    /// Mints a bookmark for `url`. Must be called while the URL's Powerbox grant
    /// is still live (i.e. immediately after an `NSOpenPanel` returns it) — this
    /// itself doesn't extend or acquire any grant.
    static func mint(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves `data` to a security-scoped `ExportRoot`.
    ///
    /// Calls `onRefresh` with freshly-minted bookmark data when macOS reports the
    /// original stale (the folder was renamed or moved but is still reachable) —
    /// the caller is responsible for persisting it. Returns nil when the bookmark
    /// can't be resolved at all (the folder was deleted, or lives on a volume
    /// that isn't mounted); callers should treat nil as "fall back to default".
    static func resolve(_ data: Data, onRefresh: (Data) -> Void) -> ExportRoot? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }

        let root = ExportRoot(url: url, isSecurityScoped: true)
        if isStale {
            // Re-minting needs the scope held; `withAccess` provides it.
            root.withAccess { scoped in
                if let refreshed = mint(for: scoped) {
                    onRefresh(refreshed)
                }
            }
        }
        return root
    }
}
