//
//  TranscriptionLine.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 21/10/25.
//

import Foundation
import SwiftData

/// Time range for a transcription segment
struct TimeRange: Codable {
    let start_ms: Int
    let end_ms: Int
}

/// Single transcription line with speaker and time information
@Model
final class TranscriptionLine {
    var text: String
    var speakerId: Int
    var speakerName: String
    var startMs: Int
    var endMs: Int
    var timestamp: Date

    /// Bundle id of the app whose audio produced this line, when captured from
    /// system audio (nil for mic / own-voice lines). Best-effort — see
    /// docs/2026-07-07-macos-source-app-attribution.md. Optional so existing
    /// stores migrate automatically (SwiftData lightweight migration).
    var sourceAppBundleID: String?

    @Relationship(inverse: \TranscriptionSession.lines)
    var session: TranscriptionSession?

    init(
        text: String, speakerId: Int, speakerName: String, startMs: Int, endMs: Int,
        sourceAppBundleID: String? = nil, timestamp: Date = Date()
    ) {
        self.text = text
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.startMs = startMs
        self.endMs = endMs
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = timestamp
    }
}
