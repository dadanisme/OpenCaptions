//
//  MarkdownFormatter.swift
//  OgmoMac
//
//  Formats a saved session's transcript as GitHub-flavored markdown for
//  copy-to-clipboard. Mirrors the iOS `MarkdownFormatter` naming, but this
//  macOS copy formats the full transcript (metadata + lines), not the summary.
//  (The targets share no source — see CLAUDE.md "Native macOS App".)
//

import Foundation

enum MarkdownFormatter {
    /// Formats a session's metadata + full transcript as GitHub-flavored markdown.
    /// Includes the title, date, duration, and — when diarization was on — the set
    /// of speaker names and per-line speaker attribution. Empty sections are omitted.
    static func formatTranscript(session: TranscriptionSession) -> String {
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

        // Transcript
        if !sortedLines.isEmpty {
            let body = sortedLines.map(line(_:)).joined(separator: "\n\n")
            parts.append("## Transcript\n\n" + body)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    /// A single transcript line. `-1` means diarization was off — emit the plain
    /// timestamped text with no speaker label (never a placeholder like
    /// "Speaker -1"), matching the detail-view rendering.
    private static func line(_ line: TranscriptionLine) -> String {
        let time = TimestampFormatter.hms(fromMs: line.startMs)
        guard line.speakerId > 0 else { return "**[\(time)]** \(line.text)" }
        let name = line.speakerName.isEmpty ? "Speaker \(line.speakerId)" : line.speakerName
        return "**[\(time)] \(name):** \(line.text)"
    }

    /// Distinct diarized speaker names in first-appearance order (positive ids
    /// only). Empty when the session wasn't diarized.
    private static func distinctSpeakerNames(from lines: [TranscriptionLine]) -> [String] {
        var seen = Set<Int>()
        var names: [String] = []
        for line in lines where line.speakerId > 0 && !seen.contains(line.speakerId) {
            seen.insert(line.speakerId)
            names.append(line.speakerName.isEmpty ? "Speaker \(line.speakerId)" : line.speakerName)
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
