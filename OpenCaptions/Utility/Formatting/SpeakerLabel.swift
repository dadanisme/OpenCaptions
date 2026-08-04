//
//  SpeakerLabel.swift
//  OpenCaptions
//
//  The one definition of "is this speaker label still the generic placeholder?".
//
//  `TranscriptionLine.speakerName` has no sentinel for "unnamed": a LIVE session
//  stores the literal string "Speaker 3" (`TranscriberModel.appendOrAdd`), while
//  re-transcription / import store "" for non-diarized lines
//  (`PostSessionSegmentBuilder`). Both mean the same thing — nobody has named this
//  speaker — so an `isEmpty` test alone misses every live session. Every formatter
//  goes through here so they can't drift apart.
//

import Foundation

enum SpeakerLabel {

    /// The placeholder label for a speaker nobody has named. The one place this
    /// wording is spelled out — `TranscriberModel` stores exactly this string as a
    /// line's initial `speakerName`, so `isDefault` recognising it and the
    /// formatters rendering it must never drift apart.
    static func generic(id: Int) -> String {
        "Speaker \(id)"
    }

    /// True when `name` is still an auto-generated placeholder for `id` — i.e.
    /// neither a person nor an earlier summary pass has named this speaker.
    static func isDefault(_ name: String, id: Int) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == generic(id: id)
    }

    /// The label to render for a diarized line: the assigned name when there is
    /// one, else the generic "Speaker N".
    static func display(_ name: String, id: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return isDefault(trimmed, id: id) ? generic(id: id) : trimmed
    }

    /// Distinct diarized speakers (positive ids only) in first-appearance order,
    /// each paired with its current display name via `display(_:id:)`. The one
    /// shared scan other call sites (list rows, markdown export, the Edit
    /// Speakers sheet) should build on instead of re-scanning `lines`.
    static func distinctSpeakers(from lines: [TranscriptionLine]) -> [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for line in lines where line.speakerId > 0 && !seen.contains(line.speakerId) {
            seen.insert(line.speakerId)
            result.append((line.speakerId, display(line.speakerName, id: line.speakerId)))
        }
        return result
    }
}
