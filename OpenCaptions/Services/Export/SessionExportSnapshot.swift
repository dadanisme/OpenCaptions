//
//  SessionExportSnapshot.swift
//  OpenCaptions
//
//  An immutable, `Sendable` copy of everything `SessionMarkdownWriter` needs to
//  write one session's folder.
//
//  A `TranscriptionSession` is a SwiftData `@Model` — not `Sendable`, and only
//  valid on the context that vended it — so it can never be handed to the writer
//  actor. The markdown is therefore rendered wherever the session lives (the main
//  actor for a live save, a background context during backfill) and only these
//  plain values cross the boundary.
//

import Foundation

struct SessionExportSnapshot: Sendable {
    /// Folder this session's files go in, relative to the export root.
    let folderName: String
    /// The folder the session was previously exported to, when it differs — the
    /// writer renames it rather than leaving an orphan behind. Nil on a first
    /// export or when the name is unchanged.
    let previousFolderName: String?
    /// Rendered `transcript.md`.
    let transcriptMarkdown: String
    /// Rendered `summary.md`, or nil when the session has no summary yet — in
    /// which case the writer DELETES any stale file, which is how a
    /// re-transcription's cleared summary disappears from disk.
    let summaryMarkdown: String?
    /// Absolute URL of the recorded audio to mirror alongside the markdown, or nil
    /// when the session has none (recording off, or the file was dropped after an
    /// import). Nil likewise means "remove the stale copy".
    let audioSourceURL: URL?

    /// Renders a session. Must be called on the actor that owns `session`.
    init(session: TranscriptionSession, folderName: String, previousFolderName: String?) {
        self.folderName = folderName
        self.previousFolderName = previousFolderName == folderName ? nil : previousFolderName
        self.transcriptMarkdown = MarkdownFormatter.formatTranscript(session: session)
        self.summaryMarkdown = MarkdownFormatter.formatSummary(session: session)
        self.audioSourceURL = session.audioFileName.map(SessionAudioStore.url(for:))
    }
}
