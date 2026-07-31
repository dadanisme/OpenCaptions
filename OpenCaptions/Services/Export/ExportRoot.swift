//
//  ExportRoot.swift
//  OpenCaptions
//
//  The folder markdown exports are written into, plus the sandbox access bracket
//  every write must go through.
//
//  A value type (not a URL) because the two kinds of root behave differently under
//  App Sandbox: the in-container default needs no bracket at all, while a
//  user-chosen folder is only writable between `startAccessingSecurityScopedResource`
//  and its stop. Carrying that distinction alongside the URL means no call site has
//  to remember which kind it holds. `Sendable` so it can cross into
//  `SessionMarkdownWriter`.
//

import Foundation

struct ExportRoot: Sendable, Equatable {
    /// Absolute URL of the export root directory.
    let url: URL
    /// Whether `url` came from a security-scoped bookmark and therefore needs an
    /// access bracket. False for the in-container default.
    let isSecurityScoped: Bool

    /// Runs `body` with security-scoped access held, creating the root directory
    /// first so callers can assume it exists.
    ///
    /// A no-op bracket for the in-container default. When the scope can't be
    /// acquired (revoked permission, an ejected volume) `body` still runs — the
    /// write inside it simply fails and is reported non-fatally, which is the same
    /// outcome as any other I/O error and keeps this from needing its own error type.
    func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T {
        guard isSecurityScoped else {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return try body(url)
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try body(url)
    }

    /// The user-facing path, with the home directory abbreviated to `~`.
    var displayPath: String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// Canonical form for "is this the same directory?" tests.
    ///
    /// Raw `URL` equality is not enough and getting this wrong is destructive: an
    /// `NSOpenPanel` can hand back `/tmp/x` for a root stored as `/private/tmp/x`,
    /// or a URL that differs only by a trailing slash. A relocate that mistook one
    /// for a different directory would delete each folder at the "destination"
    /// before moving the identical source onto it.
    var canonicalPath: String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }
}
