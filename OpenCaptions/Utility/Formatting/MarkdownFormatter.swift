//
//  MarkdownFormatter.swift
//  OpenCaptions
//
//  Formats a saved session as GitHub-flavored markdown: metadata, the AI summary
//  (when one exists), then the full transcript. Section order and headings mirror
//  the detail view and `PDFExporter`.
//
//  Three entry points, all sharing one header so the copied and the exported text
//  can't drift: `formatSession` (Copy as Markdown — everything in one string),
//  `formatTranscript` (the exported `transcript.md`), and `formatSummary` in
//  `MarkdownFormatter+Summary` (the exported `summary.md`).
//
//  Nothing here is actor-isolated — the markdown export renders on a background
//  context during backfill — but a `TranscriptionSession` is only valid on the
//  context that vended it, so callers must stay on that context.
//

import Foundation

enum MarkdownFormatter {
    /// Formats a session's metadata + summary + full transcript as GitHub-flavored
    /// markdown. Includes the title, date, duration, and — when diarization was on —
    /// the set of speaker names and per-line speaker attribution. Empty sections
    /// (no summary yet, no lines) are omitted, so this is safe to call for a
    /// summary-only or transcript-only session.
    static func formatSession(session: TranscriptionSession) -> String {
        let lines = sortedLines(of: session)
        var parts = header(session: session, sortedLines: lines)
        parts.append(contentsOf: summarySections(session: session))
        if let transcript = transcriptSection(lines) { parts.append(transcript) }
        return parts.joined(separator: "\n\n")
    }

    /// The exported `transcript.md`: the same header as `formatSession`, then the
    /// transcript — but never the summary, which is exported as its own file so
    /// each can be fed to other tools independently.
    static func formatTranscript(session: TranscriptionSession) -> String {
        let lines = sortedLines(of: session)
        var parts = header(session: session, sortedLines: lines)
        if let transcript = transcriptSection(lines) { parts.append(transcript) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Shared sections

    /// Title + metadata block (date, duration, speakers) — the two leading parts
    /// every rendering starts with.
    ///
    /// Not `private`: `MarkdownFormatter+Summary` is a separate file (the ~250-line
    /// limit), and Swift's `private` doesn't reach across files even for extensions
    /// of the same type.
    static func header(session: TranscriptionSession, sortedLines: [TranscriptionLine]) -> [String] {
        var meta: [String] = []
        let dateString = DateFormatter.localizedString(
            from: session.sessionDate, dateStyle: .long, timeStyle: .short)
        meta.append("**Date:** \(dateString)")

        let durationMs = session.resolvedDurationMs
        if durationMs > 0 {
            meta.append("**Duration:** \(durationLabel(fromMs: durationMs))")
        }

        let speakers = distinctSpeakerNames(from: sortedLines)
        if !speakers.isEmpty {
            meta.append("**Speakers:** \(speakers.joined(separator: ", "))")
        }

        return ["# \(session.sessionTitle)", meta.joined(separator: "\n")]
    }

    /// The AI-summary sections — Overview paragraphs, Key Points bullets, and
    /// Action Items as GFM task-list items carrying their completion state.
    /// Returns an empty array when the session has no summary content, so the
    /// caller can splice it in unconditionally. Internal for the same
    /// cross-file-extension reason as `header`.
    static func summarySections(session: TranscriptionSession) -> [String] {
        var sections: [String] = []

        let paragraphs = session.summaryParagraphs.filter { !$0.isEmpty }
        if !paragraphs.isEmpty {
            sections.append("## Overview\n\n" + paragraphs.joined(separator: "\n\n"))
        }

        let keyPoints = session.summaryKeyPoints.filter { !$0.isEmpty }
        if !keyPoints.isEmpty {
            let body = keyPoints.map { "- \($0)" }.joined(separator: "\n")
            sections.append("## Key Points\n\n" + body)
        }

        // Same sort as the detail view / PDF export so the copied order matches
        // what the user sees.
        let actionItems = session.actionItems
            .sorted { $0.sortOrder < $1.sortOrder }
            .filter { !$0.text.isEmpty }
        if !actionItems.isEmpty {
            let body = actionItems
                .map { "- [\($0.isCompleted ? "x" : " ")] \($0.text)" }
                .joined(separator: "\n")
            sections.append("## Action Items\n\n" + body)
        }

        return sections
    }

    // MARK: - Helpers

    /// Lines in display order (matches the detail view's transcript sort).
    static func sortedLines(of session: TranscriptionSession) -> [TranscriptionLine] {
        session.lines.sorted { ($0.startMs, $0.timestamp) < ($1.startMs, $1.timestamp) }
    }

    /// The `## Transcript` section, or nil when there are no lines.
    private static func transcriptSection(_ sortedLines: [TranscriptionLine]) -> String? {
        guard !sortedLines.isEmpty else { return nil }
        return "## Transcript\n\n" + sortedLines.map(line(_:)).joined(separator: "\n\n")
    }

    /// A single transcript line. `-1` means diarization was off — emit the plain
    /// timestamped text with no speaker label (never a placeholder like
    /// "Speaker -1"), matching the detail-view rendering.
    private static func line(_ line: TranscriptionLine) -> String {
        let time = TimestampFormatter.hms(fromMs: line.startMs)
        guard line.speakerId > 0 else { return "**[\(time)]** \(line.text)" }
        let name = SpeakerLabel.display(line.speakerName, id: line.speakerId)
        return "**[\(time)] \(name):** \(line.text)"
    }

    /// Distinct diarized speaker names in first-appearance order (positive ids
    /// only). Empty when the session wasn't diarized.
    private static func distinctSpeakerNames(from lines: [TranscriptionLine]) -> [String] {
        var seen = Set<Int>()
        var names: [String] = []
        for line in lines where line.speakerId > 0 && !seen.contains(line.speakerId) {
            seen.insert(line.speakerId)
            names.append(SpeakerLabel.display(line.speakerName, id: line.speakerId))
        }
        return names
    }

    /// Human-readable duration (`1h 5m 3s` / `5m 3s` / `3s`) — distinct from the
    /// session-relative `h:mm:ss` offsets used for per-line timestamps.
    private static func durationLabel(fromMs ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
