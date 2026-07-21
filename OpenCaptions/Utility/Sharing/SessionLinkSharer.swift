//
//  SessionLinkSharer.swift
//  OpenCaptions
//
//  Shares an already-finished session to the web. Mirrors the live
//  `OnlineViewModel.shareSession()` flow but sources the backfill from the
//  persisted SwiftData session instead of the in-memory transcript.
//

import Foundation
import SwiftData

@MainActor
enum SessionLinkSharer {

    /// Promotes a finished session to a shared (publicly viewable) one.
    /// Idempotent: returns the existing cloud id if the session was already
    /// shared — while live or previously from history — without re-uploading
    /// any lines. Returns nil when no Firebase UID is available (signed out).
    @discardableResult
    static func share(session: TranscriptionSession, context: ModelContext) -> String? {
        if let existing = session.cloudSessionId { return existing }

        let payload = buildBackfill(from: session)
        guard let cloudId = FirestoreSyncService.shared.shareEndedSession(
            title: session.sessionTitle,
            startedAt: session.sessionDate,
            endedAt: payload.endedAt,
            speakers: payload.speakers,
            backfill: payload.backfill
        ) else { return nil }

        session.cloudSessionId = cloudId
        try? context.save()

        pushSummaryIfPresent(session: session, cloudId: cloudId)
        return cloudId
    }

    /// Re-pushes a re-transcribed session's transcript to its EXISTING shared link so
    /// the web copy matches after re-transcription (#245). No-op if the session was
    /// never shared. The summary is re-pushed separately by the caller's summary
    /// regeneration (online) or left cleared on the web (offline) — consistent with
    /// the local state either way.
    static func resyncShared(session: TranscriptionSession) {
        guard let cloudId = session.cloudSessionId else { return }
        let payload = buildBackfill(from: session)
        FirestoreSyncService.shared.resyncSharedSession(
            cloudSessionId: cloudId,
            title: session.sessionTitle,
            startedAt: session.sessionDate,
            endedAt: payload.endedAt,
            speakers: payload.speakers,
            backfill: payload.backfill
        )
    }

    // MARK: - Helpers

    /// Rebuilds the share backfill from persisted lines, in transcript order.
    /// `bubbleId` is the sorted index — ids only need to be unique and lexically
    /// ordered within this session. `timestamp` tiebreaks equal `startMs` (e.g.
    /// consecutive manual messages that reuse the last known end time), since Swift's
    /// sort isn't stable, so `startMs` alone could scramble their order.
    private static func buildBackfill(
        from session: TranscriptionSession
    ) -> (speakers: [Int: String], backfill: [FirestoreSyncService.BackfillLine], endedAt: Date) {
        let sortedLines = session.lines.sorted {
            ($0.startMs, $0.timestamp) < ($1.startMs, $1.timestamp)
        }
        var speakers: [Int: String] = [:]
        var backfill: [FirestoreSyncService.BackfillLine] = []
        backfill.reserveCapacity(sortedLines.count)
        for (index, line) in sortedLines.enumerated() {
            speakers[line.speakerId] = line.speakerName
            backfill.append(FirestoreSyncService.BackfillLine(
                text: line.text,
                speakerId: line.speakerId,
                startMs: line.startMs,
                endMs: line.endMs,
                bubbleId: index
            ))
        }
        // Best-effort end time: session start plus the last line's offset.
        let endedAt = sortedLines.last
            .map { session.sessionDate.addingTimeInterval(TimeInterval($0.endMs) / 1000) }
            ?? session.sessionDate
        return (speakers, backfill, endedAt)
    }

    /// Pushes the existing AI summary (if any) so the web view matches the app.
    private static func pushSummaryIfPresent(session: TranscriptionSession, cloudId: String) {
        let hasSummary = !session.summaryParagraphs.isEmpty
            || !session.summaryKeyPoints.isEmpty
            || !session.actionItems.isEmpty
        guard hasSummary else { return }
        FirestoreSyncService.shared.writeSummary(
            cloudSessionId: cloudId,
            paragraphs: session.summaryParagraphs,
            keyPoints: session.summaryKeyPoints,
            actionItems: session.actionItems
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.text),
            title: session.sessionTitle,
            shortDescription: session.shortDescription ?? ""
        )
    }
}
