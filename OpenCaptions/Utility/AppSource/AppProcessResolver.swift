//
//  AppProcessResolver.swift
//  OgmoMac
//
//  Maps an audio process's PID to the user-facing APP it belongs to, so audio
//  produced by a helper / child process attributes to the parent app rather than
//  a helper with a blank (or missing) icon. Many apps output audio from a child
//  process: Chromium-based apps (Chrome, Steam, Electron) use renderer/GPU
//  helpers; the helpers are children of the main app process, so walking the
//  parent-PID chain reaches the real app.
//
//  App-Store-safe: parent pid via the public `sysctl` BSD API, app identity via
//  `NSRunningApplication`. No private "responsibility" API. Returns nil when no
//  ancestor is a launchable app (e.g. WebKit XPC services reparented to launchd),
//  so the caller can fall back to the process's own bundle id.
//

import AppKit
import Darwin

/// Stored as a line's `sourceAppBundleID` when system audio was playing but
/// couldn't be attributed to a nameable app (Safari/WebKit and FaceTime route
/// audio through shared macOS services with no public path back to the app; some
/// helper states also don't resolve). Rendered as a neutral speaker glyph. Not a
/// real bundle id, so it never resolves to an app icon.
enum SourceAppMarker {
    static let unknownSystemAudio = "__ogmo_unknown_system_audio__"
}

enum AppProcessResolver {

    private static var cache: [pid_t: String?] = [:]
    private static let lock = NSLock()

    /// The owning app's bundle id for `pid`, walking up parents. Cached per pid.
    static func appBundleID(forPID pid: pid_t) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[pid] { return cached }
        let resolved = resolve(pid: pid, depth: 0)
        cache[pid] = resolved
        return resolved
    }

    private static func resolve(pid: pid_t, depth: Int) -> String? {
        guard pid > 1, depth < 8 else { return nil }
        let mine = launchableBundleID(forPID: pid)
        let parent = parentPID(of: pid).flatMap { $0 != pid ? resolve(pid: $0, depth: depth + 1) : nil }

        // Collapse a helper to its owning app: when an ancestor app's bundle id is
        // a dotted prefix of this process's (com.valvesoftware.steam ⊂
        // com.valvesoftware.steam.helper, or a Chromium/Electron *.helper.*), prefer
        // the ancestor so we show the app's icon, not the helper's blank one.
        if let mine, let parent, mine.hasPrefix(parent + ".") { return parent }
        // Otherwise take this process if it's a launchable app (WhatsApp, main
        // Chrome/Steam), else whatever the walk found upstream (Chrome/WebKit
        // helpers aren't launchable themselves → their hosting app, or nil).
        return mine ?? parent
    }

    /// This pid's bundle id, but only if it maps to a LAUNCHABLE app (resolves to
    /// an app URL → has an icon). WebKit's GPU/content processes report themselves
    /// as running apps but aren't launchable, so they return nil and the caller
    /// keeps walking up to the hosting app.
    private static func launchableBundleID(forPID pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy != .prohibited,
              let bundleID = app.bundleIdentifier,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        else { return nil }
        return bundleID
    }

    /// Parent pid via `sysctl(KERN_PROC_PID)` (public BSD API).
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
