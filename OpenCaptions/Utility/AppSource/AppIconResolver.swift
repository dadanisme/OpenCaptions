//
//  AppIconResolver.swift
//  OgmoMac
//
//  Resolves a source-app bundle id to its app icon + display name for the
//  transcript's source-app glyph (`SourceAppIcon`). Results are cached — icon
//  lookups hit LaunchServices / the filesystem, and the same handful of apps
//  recur across a session. A bundle id that doesn't resolve to an installed app
//  (e.g. a helper/system process) yields nil, so the glyph simply doesn't render.
//

import AppKit

enum AppIconResolver {

    private struct Entry {
        let icon: NSImage?
        let name: String?
    }

    private static var cache: [String: Entry] = [:]
    private static let lock = NSLock()

    static func icon(forBundleID id: String) -> NSImage? { entry(for: id).icon }
    static func name(forBundleID id: String) -> String? { entry(for: id).name }

    private static func entry(for id: String) -> Entry {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] { return cached }

        let entry: Entry
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? FileManager.default.displayName(atPath: url.path)
            entry = Entry(icon: NSWorkspace.shared.icon(forFile: url.path), name: name)
        } else {
            entry = Entry(icon: nil, name: nil)
        }
        cache[id] = entry
        return entry
    }
}
