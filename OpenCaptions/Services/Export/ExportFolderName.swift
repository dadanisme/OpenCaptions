//
//  ExportFolderName.swift
//  OpenCaptions
//
//  Turns a session's date + title into the folder name its markdown lives in.
//
//  Shape is `<yyyy-MM-dd>-<slug>` so a Finder listing sorts chronologically
//  without anyone setting a sort column. The date part is deliberately NOT
//  localized (`DateFormatter.localizedString` would emit `29/07/2026` in some
//  locales, which sorts wrong and contains a path separator).
//

import Foundation

enum ExportFolderName {

    /// Longest slug we'll emit. Kept well under the 255-byte HFS+/APFS filename
    /// limit so the date prefix, a dedupe suffix, and any multi-byte characters
    /// still fit.
    private static let maxSlugLength = 60

    /// Fixed-format `yyyy-MM-dd`, POSIX locale so it can't be localized out of
    /// sortable shape.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Building

    /// The folder name a session *wants*, before collision resolution.
    static func make(date: Date, title: String) -> String {
        "\(dateFormatter.string(from: date))-\(slugify(title))"
    }

    /// Lowercased, hyphen-joined, filesystem-safe form of a title.
    ///
    /// Strips path separators (`/`) and the HFS-legacy separator (`:`), collapses
    /// runs of whitespace and punctuation to a single hyphen, and drops leading
    /// dots so nothing lands as a hidden folder. Falls back to `"session"` when the
    /// title has no usable characters at all (e.g. an emoji-only title).
    static func slugify(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = ""
        var pendingSeparator = false

        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                if pendingSeparator && !slug.isEmpty { slug.unicodeScalars.append("-") }
                pendingSeparator = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }

        slug = slug.lowercased()
        if slug.count > maxSlugLength {
            // Trim on a hyphen boundary when there is one nearby, so the name ends
            // on a whole word rather than mid-syllable.
            slug = String(slug.prefix(maxSlugLength))
            if let lastHyphen = slug.lastIndex(of: "-"), slug.distance(from: lastHyphen, to: slug.endIndex) < 12 {
                slug = String(slug[slug.startIndex..<lastHyphen])
            }
        }
        return slug.isEmpty ? "session" : slug
    }

    // MARK: - Collision resolution

    /// `desired`, or `desired-2` / `desired-3` / … when that name is already taken
    /// by a different session.
    ///
    /// - Parameters:
    ///   - keeping: this session's current folder name. Never treated as a
    ///     collision — a session must be able to keep (or rename onto) its own
    ///     folder.
    ///   - claimed: names handed out earlier in this app run whose folders may not
    ///     be on disk yet. Two sessions saved back-to-back with the same day and
    ///     title would otherwise both pass the `fileExists` check and pick the same
    ///     name; the writer runs asynchronously, so disk alone can't arbitrate.
    static func resolveCollision(
        _ desired: String,
        in root: ExportRoot,
        keeping current: String?,
        claimed: Set<String>
    ) -> String {
        root.withAccess { rootURL in
            let fileManager = FileManager.default
            var candidate = desired
            var suffix = 1
            while candidate != current
                && (claimed.contains(candidate)
                    || fileManager.fileExists(atPath: rootURL.appendingPathComponent(candidate).path)) {
                suffix += 1
                candidate = "\(desired)-\(suffix)"
            }
            return candidate
        }
    }
}
