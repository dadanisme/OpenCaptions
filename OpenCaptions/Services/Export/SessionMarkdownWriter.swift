//
//  SessionMarkdownWriter.swift
//  OpenCaptions
//
//  Every filesystem operation the markdown export performs — write, rename,
//  delete, relocate. The only file in `Services/Export/` that touches disk.
//
//  An `actor` for two reasons. It moves the I/O off the main actor (a save must
//  never wait on a 14 MB audio copy), and it SERIALIZES the operations: a summary
//  landing while a re-transcription is still writing would otherwise race on the
//  same folder. Nothing here throws to its caller — the SwiftData row is the source
//  of truth and a failed mirror is logged, never surfaced as an error the user has
//  to dismiss. See docs/2026-07-31-macos-markdown-export.md.
//

import Foundation

actor SessionMarkdownWriter {
    static let shared = SessionMarkdownWriter()

    private let fileManager = FileManager.default

    private enum FileName {
        static let transcript = "transcript.md"
        static let summary = "summary.md"
        static let audio = "audio.m4a"
    }

    // MARK: - Write

    /// Writes (or rewrites) one session's folder: renames it first when the title
    /// changed, then lays down `transcript.md`, `summary.md`, and the audio mirror.
    func write(_ snapshot: SessionExportSnapshot, to root: ExportRoot) {
        root.withAccess { rootURL in
            let folder = rootURL.appendingPathComponent(snapshot.folderName, isDirectory: true)

            // Rename before writing so the existing files (notably the audio copy,
            // the expensive one) move with the folder instead of being re-created.
            if let previous = snapshot.previousFolderName {
                let previousFolder = rootURL.appendingPathComponent(previous, isDirectory: true)
                if fileManager.fileExists(atPath: previousFolder.path) {
                    do {
                        try fileManager.moveItem(at: previousFolder, to: folder)
                    } catch {
                        log("rename \(previous) → \(snapshot.folderName)", error)
                    }
                }
            }

            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                log("create \(snapshot.folderName)", error)
                return
            }

            writeText(snapshot.transcriptMarkdown, to: folder.appendingPathComponent(FileName.transcript))

            // No summary means "delete the stale one" — this is how a
            // re-transcription's cleared summary leaves disk.
            let summaryURL = folder.appendingPathComponent(FileName.summary)
            if let summary = snapshot.summaryMarkdown {
                writeText(summary, to: summaryURL)
            } else {
                removeIfPresent(summaryURL)
            }

            mirrorAudio(from: snapshot.audioSourceURL, into: folder)
        }
    }

    // MARK: - Remove

    /// Deletes a session's exported folder. No-op when it was never exported or is
    /// already gone.
    func remove(folderNames: [String], from root: ExportRoot) {
        guard !folderNames.isEmpty else { return }
        root.withAccess { rootURL in
            for name in folderNames {
                removeIfPresent(rootURL.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    // MARK: - Relocate

    /// Moves every exported session folder from one root to another when the user
    /// picks a new destination in Settings.
    ///
    /// Deliberately reads the OLD ROOT rather than SwiftData: the Settings window
    /// can be opened without the main window ever existing, so no `ModelContainer`
    /// is guaranteed to be in hand — and the folders themselves are a complete
    /// record of what needs moving. Safe ONLY when `old` is a root nothing else
    /// writes into (the single shared default, or a workspace folder already
    /// exclusive to it) — moving every folder found under a root that other
    /// sessions/workspaces might also be using would steal folders that aren't
    /// this caller's to move. A workspace changing away from the shared default
    /// for the first time must relocate session-by-session instead — see
    /// `relocateOne`.
    ///
    /// Both roots are bracketed at once — the old one must still be security-scoped
    /// while its contents are read. Returns the names it could NOT move, so the
    /// caller can re-export those sessions into the new root instead of leaving a gap.
    func relocateAll(from old: ExportRoot, to new: ExportRoot) -> [String] {
        // Compared canonically, not by `URL` equality: the panel can hand back
        // `/tmp/x` for a root resolved as `/private/tmp/x`. Treating those as
        // different would send every folder through `removeIfPresent(destination)`
        // with destination == source, deleting the entire archive.
        guard old.canonicalPath != new.canonicalPath else { return [] }
        return old.withAccess { oldRoot -> [String] in
            new.withAccess { newRoot -> [String] in
                let contents = (try? fileManager.contentsOfDirectory(
                    at: oldRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                var failed: [String] = []
                for source in contents {
                    guard (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    else { continue }
                    let name = source.lastPathComponent
                    if !moveIfOurs(name, from: oldRoot, to: newRoot) {
                        failed.append(name)
                    }
                }
                return failed
            }
        }
    }

    /// Moves a single session's folder between two roots — a workspace
    /// reassignment or a workspace's own folder change, where bulk-moving
    /// everything under the old root (`relocateAll`) would risk touching folders
    /// that belong to a different session/workspace still using that root.
    ///
    /// Returns true when there was nothing to do (the session was never exported,
    /// or the two roots are the same) as well as on a successful move — false only
    /// when a real move was needed and didn't happen, so the caller can clear
    /// `exportFolderName` and let the next export write a fresh, deduped name.
    func relocateOne(folderName: String, from old: ExportRoot, to new: ExportRoot) -> Bool {
        guard old.canonicalPath != new.canonicalPath else { return true }
        return old.withAccess { oldRoot in
            new.withAccess { newRoot in
                moveIfOurs(folderName, from: oldRoot, to: newRoot)
            }
        }
    }

    /// Moves one named folder from `oldRoot` to `newRoot`, the shared guard both
    /// `relocateAll` and `relocateOne` use. `transcript.md` inside is the ownership
    /// marker: a folder without one wasn't written by this app (the chosen root may
    /// be one the user keeps other things in) and is left alone, counted as
    /// "nothing to do" rather than a failure.
    private func moveIfOurs(_ name: String, from oldRoot: URL, to newRoot: URL) -> Bool {
        let source = oldRoot.appendingPathComponent(name, isDirectory: true)
        guard isExportFolder(source) else { return true }

        let destination = newRoot.appendingPathComponent(name, isDirectory: true)
        guard source.resolvingSymlinksInPath().standardizedFileURL
                != destination.resolvingSymlinksInPath().standardizedFileURL
        else { return true }

        // A folder already sitting at the destination would make `moveItem`
        // throw. Clear it ONLY when it is one of ours — the chosen folder may be
        // one the user keeps other things in, and a same-named folder of theirs
        // must never be destroyed. When it isn't ours, give up and let the caller
        // re-export this session under a deduped name instead.
        if fileManager.fileExists(atPath: destination.path) {
            guard isExportFolder(destination) else {
                log("move \(name)", RelocateError.destinationOccupied)
                return false
            }
            removeIfPresent(destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            log("move \(name)", error)
            return false
        }
    }

    /// Whether a directory is one this app wrote — the only test that authorises
    /// deleting or moving it. A `transcript.md` inside is the marker; every export
    /// has one and nothing else here creates one.
    private func isExportFolder(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(FileName.transcript).path)
    }

    private enum RelocateError: LocalizedError {
        case destinationOccupied
        var errorDescription: String? {
            "a folder of that name already exists there and wasn't written by Open Captions"
        }
    }

    // MARK: - Primitives

    /// Writes `text` only when it differs from what's already there, so a
    /// re-export that changed nothing doesn't bump the file's modification date
    /// (which would churn Finder, Spotlight, and any folder watcher).
    private func writeText(_ text: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("write \(url.lastPathComponent)", error)
        }
    }

    /// Copies the session recording next to its markdown, or removes the stale copy
    /// when the session no longer has audio.
    ///
    /// Skips the copy when size and modification date already match: audio is by
    /// far the largest thing here, and a session is re-exported on every summary,
    /// rename, and action-item toggle.
    private func mirrorAudio(from source: URL?, into folder: URL) {
        let destination = folder.appendingPathComponent(FileName.audio)
        guard let source, fileManager.fileExists(atPath: source.path) else {
            removeIfPresent(destination)
            return
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let sourceInfo = try? source.resourceValues(forKeys: keys)
        if let destinationInfo = try? destination.resourceValues(forKeys: keys),
           destinationInfo.fileSize == sourceInfo?.fileSize,
           destinationInfo.contentModificationDate == sourceInfo?.contentModificationDate {
            return
        }
        removeIfPresent(destination)
        do {
            try fileManager.copyItem(at: source, to: destination)
            // Carry the source's mtime over so the skip-check above matches next time
            // (`copyItem` preserves it, but a failed attribute copy would not).
            if let modified = sourceInfo?.contentModificationDate {
                try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
            }
        } catch {
            log("copy audio", error)
        }
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            log("remove \(url.lastPathComponent)", error)
        }
    }

    private func log(_ operation: String, _ error: Error) {
        print("⚠️ Markdown export: failed to \(operation) — \(error.localizedDescription)")
    }
}
