//
//  TranscriptionSession.swift
//  OpenCaptions
//
//  Created by Wentao Guo on 21/10/25.
//

import Foundation
import SwiftData

/// Transcription session containing multiple lines
@Model
final class TranscriptionSession {
    var sessionDate: Date
    var sessionTitle: String
    var shortDescription: String?
    /// Firebase UID of the user who owns this session. Optional for backward
    /// compatibility: legacy rows recorded before multi-user support have `nil`
    /// and are backfilled to the current user at launch (see `SessionOwnerBackfill`).
    var userId: String?
    var summaryParagraphs: [String] = []
    var summaryKeyPoints: [String] = []
    /// Stable UUID that ties this local session to the mirrored Firestore document
    /// at `users/{uid}/sessions/{cloudSessionId}`. Nil if Share Session was off
    /// when this session was recorded.
    var cloudSessionId: String?
    /// Cached session duration in milliseconds so list cards never scan `lines`.
    /// Nil means "not yet computed" (legacy row) — backfilled at app launch.
    var durationMs: Int?
    /// Cached preview (first lines of the transcript) so list cards never
    /// sort/scan `lines`. Nil means "not yet computed" (legacy row).
    var previewText: String?
    /// Filename (not path) of the session's recorded audio under
    /// Application Support/SessionAudio, resolved via `SessionAudioStore.url(for:)`.
    /// Nil when audio wasn't captured (recording disabled, legacy row, or a
    /// discarded/empty session). Optional so existing stores migrate
    /// automatically (SwiftData lightweight migration).
    var audioFileName: String?
    /// Server-owned flag mirrored from `sessionIndex/{cloudSessionId}.hasPassword`.
    /// The client NEVER writes this to Firestore (the Cloud Function flips it);
    /// cached here so list/detail show the lock state offline. Refreshed on
    /// detail-view appear and after set/remove.
    var hasPassword: Bool = false
    @Relationship(deleteRule: .cascade) var actionItems: [ActionItem] = []

    @Relationship(deleteRule: .cascade)
    var lines: [TranscriptionLine] = []

    init(sessionDate: Date = Date(), sessionTitle: String = "", shortDescription: String? = nil, cloudSessionId: String? = nil, userId: String? = nil) {
        self.sessionDate = sessionDate
        self.sessionTitle = sessionTitle.isEmpty ? "Session \(DateFormatter.localizedString(from: sessionDate, dateStyle: .short, timeStyle: .short))" : sessionTitle
        self.shortDescription = shortDescription
        self.cloudSessionId = cloudSessionId
        self.userId = userId
    }
}
