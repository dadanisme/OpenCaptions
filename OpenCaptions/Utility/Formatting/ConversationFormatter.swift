//
//  ConversationFormatter.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 17/11/25.
//

import Foundation

enum ConversationFormatter {
    /// The flat transcript blob sent to Gemini as the summary request's `contents`.
    /// Its ONLY caller is `SummaryService.summarize(session:language:)` — the
    /// user-facing transcript exports go through `MarkdownFormatter` instead — so
    /// this format is free to carry model-facing scaffolding (the speaker roster,
    /// the numeric speaker ids) that no human ever reads.
    ///
    /// Every diarized line keeps its numeric id in the label, even once the speaker
    /// has a name, because the summary response maps its speaker predictions back
    /// by id (see `SpeakerNameResolver`). Dropping the id here would leave nothing
    /// for `speakerId` in the response to refer to.
    static func buildTranscript(from session: TranscriptionSession) -> String {

        let sortedLines = session.lines.sorted { $0.startMs < $1.startMs }

        let header = """
        Session title：\(session.sessionTitle)
        Session Date：\(DateFormatter.localizedString(from: session.sessionDate,
                                               dateStyle: .medium,
                                               timeStyle: .short))
        \(roster(from: sortedLines))
        Here is the complete dialogue (with timestamps, speaker ids, and any names already assigned)：
        """

        let body = sortedLines.map { line in
            let time = formatMs(line.startMs)
            // A non-positive id means diarization was off for this line — emit plain
            // timestamped text with no speaker label rather than a placeholder like
            // "Speaker #-1". Matches `MarkdownFormatter` and every view.
            if line.speakerId <= 0 {
                return "[\(time)] \(line.text)"
            }
            return "[\(time)] \(label(for: line))：\(line.text)"
        }.joined(separator: "\n")

        return header + "\n\n" + body
    }

    // MARK: - Speakers

    /// A speaker's label: always "Speaker {id}", with any assigned name appended
    /// in parentheses. Additive rather than a replacement so the id survives a
    /// rename — which is what makes the response's `speakerId` resolvable.
    private static func label(for line: TranscriptionLine) -> String {
        let generic = SpeakerLabel.generic(id: line.speakerId)
        guard !SpeakerLabel.isDefault(line.speakerName, id: line.speakerId) else { return generic }
        return "\(generic) (\(SpeakerLabel.display(line.speakerName, id: line.speakerId)))"
    }

    /// The roster block listing every diarized speaker id once, in ascending id
    /// order. It bounds the id space so the model can't predict a name for an id
    /// that isn't in the session. Empty (no block at all) for a non-diarized
    /// session, so that transcript keeps its original layout. Note the test is
    /// `speakerId > 0`, not "is anyone named" — a diarized session whose speakers
    /// are all still generic gets a roster of generic labels, which is exactly
    /// what the first summary pass needs.
    ///
    /// Built from the same `label(for:)` as the body — two separate renderings
    /// would eventually disagree and hand the model contradictory input.
    private static func roster(from sortedLines: [TranscriptionLine]) -> String {
        // Lines with the same id share a name, so the first occurrence is
        // authoritative — the same rule `editableSpeakers` uses for the edit sheet.
        var labelById: [Int: String] = [:]
        for line in sortedLines where line.speakerId > 0 && labelById[line.speakerId] == nil {
            labelById[line.speakerId] = label(for: line)
        }
        guard !labelById.isEmpty else { return "" }
        let entries = labelById.keys.sorted().compactMap { labelById[$0] }
        // The leading/trailing newlines keep the block set off by a blank line on
        // each side; with no diarized speakers the empty string collapses back to
        // the original single blank line.
        return "\nDiarized speakers in this session：\n"
            + entries.map { "- \($0)" }.joined(separator: "\n")
            + "\n"
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
