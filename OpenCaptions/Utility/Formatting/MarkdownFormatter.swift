//
//  MarkdownFormatter.swift
//  OpenCaptions
//
//  Formats a saved session as GitHub-flavored markdown for copy-to-clipboard:
//  metadata, the AI summary (when one exists), then the full transcript. Section
//  order and headings mirror the detail view and `PDFExporter`.
//

import Foundation

enum MarkdownFormatter {
    /// Formats a session's metadata + summary + full transcript as GitHub-flavored
    /// markdown. Includes the title, date, duration, and — when diarization was on —
    /// the set of speaker names and per-line speaker attribution. Empty sections
    /// (no summary yet, no lines) are omitted, so this is safe to call for a
    /// summary-only or transcript-only session.
    static func formatSession(session: TranscriptionSession) -> String {
        var parts: [String] = []

        // Title
        parts.append("# \(session.sessionTitle)")

        // Lines in display order (matches the detail view's transcript sort).
        let sortedLines = session.lines.sorted {
            ($0.startMs, $0.timestamp) < ($1.startMs, $1.timestamp)
        }

        // Metadata block (date, duration, speakers).
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
        parts.append(meta.joined(separator: "\n"))

        // Summary (omitted entirely when the session hasn't been summarized).
        parts.append(contentsOf: summarySections(session: session))

        // Transcript
        if !sortedLines.isEmpty {
            let body = sortedLines.map(line(_:)).joined(separator: "\n\n")
            parts.append("## Transcript\n\n" + body)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Summary

    /// The AI-summary sections — Overview paragraphs, Key Points bullets, and
    /// Action Items as GFM task-list items carrying their completion state.
    /// Returns an empty array when the session has no summary content, so the
    /// caller can splice it in unconditionally.
    private static func summarySections(session: TranscriptionSession) -> [String] {
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
