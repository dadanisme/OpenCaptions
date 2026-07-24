//
//  ConversationFormatter.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 17/11/25.
//

import Foundation

enum ConversationFormatter {
    static func buildTranscript(from session: TranscriptionSession) -> String {
    
        let sortedLines = session.lines.sorted { $0.startMs < $1.startMs }

        let header = """
        Session title：\(session.sessionTitle)
        Session Date：\(DateFormatter.localizedString(from: session.sessionDate,
                                               dateStyle: .medium,
                                               timeStyle: .short))

        Here is the complete dialogue (with timestamps and speakers)：
        """

        let body = sortedLines.map { line in
            let time = formatMs(line.startMs)
            // `-1` means diarization was off — emit plain timestamped text with no
            // speaker label rather than a placeholder like "Speaker #-1".
            if line.speakerId == -1 {
                return "[\(time)] \(line.text)"
            }
            let speaker = line.speakerName.isEmpty ? "Speaker \(line.speakerId)" : line.speakerName
            return "[\(time)] \(speaker)：\(line.text)"
        }.joined(separator: "\n")

        return header + "\n\n" + body
    }

    private static func formatMs(_ ms: Int) -> String {
        TimestampFormatter.hms(fromMs: ms)
    }

    /// Session-relative `h:mm:ss` timestamp shown next to a transcript line's
    /// speaker.
    static func speakerTimestamp(fromMs ms: Int) -> String {
        TimestampFormatter.hms(fromMs: ms)
    }

    /// Playback clock for the audio player's elapsed/total labels: `h:mm:ss` once
    /// a session reaches an hour (lectures can), else `m:ss` (matching the
    /// transcript timestamps).
    static func playbackTime(fromMs ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
