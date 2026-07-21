//
//  SessionAudioStore.swift
//  OgmoMac
//
//  On-disk location + lifecycle for recorded session audio.
//

import Foundation

/// Resolves and cleans up recorded session audio files.
///
/// Files live in `Application Support/SessionAudio/<uuid>.m4a`. Inside the app
/// sandbox this resolves to the app's own container, so no extra entitlement is
/// needed. Only the *filename* is persisted on `TranscriptionSession`; the
/// absolute URL is resolved here at read time, so a container-path change never
/// invalidates a stored reference.
enum SessionAudioStore {
    private static let folderName = "SessionAudio"

    /// The `SessionAudio` directory, created on first access. Falls back to the
    /// temporary directory if Application Support is somehow unavailable.
    static var directory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Absolute URL for a stored audio filename.
    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Removes a stored file. No-op when `fileName` is nil or already gone.
    static func delete(fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Deletes any `.m4a` in the directory not referenced by a saved session —
    /// clears partial files left by a crash (an unreferenced, likely-unplayable
    /// recording whose session row was never stamped with its filename).
    static func sweepOrphans(referenced: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "m4a" {
            if !referenced.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
