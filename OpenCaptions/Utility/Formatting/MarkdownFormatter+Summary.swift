//
//  MarkdownFormatter+Summary.swift
//  OpenCaptions
//
//  The exported `summary.md`: the AI summary on its own, without the transcript.
//
//  Split from `MarkdownFormatter` for the ~250-line limit, and because this is the
//  one rendering that can legitimately produce NOTHING — a session with no summary
//  yet has no `summary.md`, and `nil` is what tells `SessionMarkdownWriter` to
//  delete a stale one (how a re-transcription's cleared summary leaves disk).
//

import Foundation

extension MarkdownFormatter {
    /// The session's summary as standalone markdown — the same header as
    /// `formatTranscript`, then Overview / Key Points / Action Items.
    ///
    /// Returns nil when the session has no summary content at all, which is a
    /// normal state (not yet summarized, offline-captured, or just re-transcribed),
    /// not a failure. Field set matches `PDFExporter.exportSummary`, with action
    /// items additionally carrying their completion state as GFM task-list items.
    static func formatSummary(session: TranscriptionSession) -> String? {
        let sections = summarySections(session: session)
        guard !sections.isEmpty else { return nil }

        var parts = header(session: session, sortedLines: sortedLines(of: session))
        if let description = session.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            // The one-line gist the summary pass produces. It has no home in
            // `formatSession` (the detail view doesn't show it either), but in a
            // standalone summary file it's the most useful line on the page — it's
            // what a folder-scanning tool or an LLM reads first.
            parts.append("> \(description)")
        }
        parts.append(contentsOf: sections)
        return parts.joined(separator: "\n\n")
    }
}
