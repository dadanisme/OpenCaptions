//
//  FeatureFlagService.swift
//  OpenCaptions
//
//  Real-time feature-flag reader for the macOS app. Subscribes to a single
//  Firestore doc (`config/featureFlags`) so the team can toggle features
//  remotely without an app release, and resolves every flag through a
//  three-tier fallback:
//
//      remote value  ->  cached remote value  ->  compile-time default
//
//  The cache (UserDefaults) is read synchronously in `init()` so launch-time UI
//  gates resolve instantly, before the async listener's first callback. Only
//  remote-sourced values are ever cached — compile-time defaults stay in
//  `FeatureFlag.defaultValue` so a future app version can change a default
//  without a stale cache shadowing it.
//
//  Ported from the iOS `unmute` target. The Mac uses its own cache key and
//  reads `Mac_`-prefixed flag keys (see `FeatureFlag`). Threading: `@MainActor`;
//  the Firestore listener callback hops back onto the main actor before
//  mutating state. See docs/2026-07-06-macos-firestore-share.md.
//

import FirebaseFirestore
import Foundation
import Observation

@Observable
@MainActor
final class FeatureFlagService {

    static let shared = FeatureFlagService()

    // MARK: - Firestore field names (single source of truth for reader ↔ admin)

    private enum F {
        static let collection = "config"
        static let document = "featureFlags"
        /// Map field on the doc: `{ "<flag key>": <bool> }`.
        static let flags = "flags"
    }

    /// Mac-distinct cache key so it never collides with the iOS app's cache.
    private static let cacheKey = "mac_featureFlagsCache"

    // MARK: - State

    /// Remote-sourced flag values keyed by `FeatureFlag.rawValue`. Fully private:
    /// all reads go through `isEnabled(_:)` so a flag the backend isn't managing
    /// resolves to its compile-time `defaultValue` rather than a bare `nil`.
    private var flags: [String: Bool]

    /// Live Firestore subscription. Kept for the process lifetime; the handle
    /// backs the idempotency guard in `startListening()`.
    @ObservationIgnored private var listener: ListenerRegistration?

    private init() {
        // Synchronous cache read — no Firebase access here, so previews (which
        // never call FirebaseApp.configure) construct the singleton safely.
        flags = Self.loadCache()
    }

    // MARK: - Public API

    /// The resolved value of a flag: remote/cached value if present, else the
    /// compile-time default. Reading this inside a SwiftUI `body` establishes an
    /// Observation dependency, so views re-render when a flag flips at runtime.
    func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag.rawValue] ?? flag.defaultValue
    }

    /// Attaches the realtime listener. Idempotent and safe to call from a view
    /// `.task` that re-runs (e.g. the sign-out → sign-in flow): the guard
    /// collapses repeat calls into a no-op so listeners never stack.
    func startListening() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        guard listener == nil else { return }

        let docRef = Firestore.firestore()
            .collection(F.collection)
            .document(F.document)

        listener = docRef.addSnapshotListener { [weak self] snapshot, error in
            // Never overwrite good state on failure: a permission/error callback
            // yields a nil snapshot, and clobbering `flags`/cache with emptiness
            // would silently drop every flag to its default mid-session.
            guard error == nil, let snapshot else {
                print("⚠️ FeatureFlag listener failed: \(error?.localizedDescription ?? "nil snapshot")")
                return
            }
            let remote = Self.parseFlags(from: snapshot)
            Task { @MainActor [weak self] in
                self?.apply(remote)
            }
        }
    }

    // MARK: - Snapshot handling

    /// Publishes a fresh snapshot. Rebuilds `flags` wholesale (rather than
    /// merging) so a flag removed from the remote map correctly reverts to its
    /// compile-time default, and mirrors the same map into the cache.
    private func apply(_ remote: [String: Bool]) {
        flags = remote
        persistCache(remote)
    }

    /// Extracts the `flags` map, keeping only genuine boolean entries. A missing
    /// doc, missing field, or malformed value yields no entry for that key — so
    /// it falls through to `defaultValue` instead of being coerced to `false`.
    private static func parseFlags(from snapshot: DocumentSnapshot) -> [String: Bool] {
        guard let raw = snapshot.get(F.flags) as? [String: Any] else { return [:] }
        var result: [String: Bool] = [:]
        for (key, value) in raw {
            if let enabled = value as? Bool { result[key] = enabled }
        }
        return result
    }

    // MARK: - Cache (UserDefaults JSON; remote values only)

    private static func loadCache() -> [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persistCache(_ map: [String: Bool]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
