//
//  PostSessionRetranscriber.swift
//  OpenCaptions
//
//  The shared core for post-session re-transcription: runs a chosen engine over a
//  saved recording, replaces the session transcript, and
//  regenerates the summary. Driven by `RetranscriptionManager` for BOTH the manual and
//  automatic paths, so the two can never diverge.
//  See docs/2026-07-16-macos-post-session-retranscription.md.
//

import Foundation
import SwiftData

enum PostSessionRetranscriber {

    /// Runs `kind` over `audioURL` and applies the result to `session`.
    ///
    /// - Throws: `PostSessionEngineError` on failure, `CancellationError` if cancelled.
    @MainActor
    static func run(
        kind: RetranscriptionEngineKind,
        session: TranscriptionSession,
        audioURL: URL,
        context: ModelContext,
        userName: String?,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws {
        let engine = PostSessionRetranscriptionFactory.make(kind, userName: userName)
        let tokens = try await engine.transcribe(audioURL: audioURL, progress: progress)
        try Task.checkCancellation()

        progress(PostSessionProgress(stage: .finalizing))
        let lines = PostSessionSegmentBuilder.build(from: tokens)
        guard !lines.isEmpty else { throw PostSessionEngineError.emptyResult }
        replaceTranscript(with: lines, in: session, context: context)

        // Regenerate the summary from the fresh transcript, when the selected Summary
        // Model can actually run — independent of `kind` (the retranscription engine):
        // which engine re-transcribed the audio has no bearing on which model can
        // summarize the result. The (now-cleared) summary can be generated later
        // when unavailable now.
        if LiveSessionStore.summaryProviderKind.isAvailable {
            await SummaryViewModel().generateSummary(session: session, context: context)
        }
    }

    // MARK: - Replace

    /// Overwrites the session's lines with `lines`, clears the now-stale summary, and
    /// refreshes the cached derived fields (duration + preview) the list cards read.
    @MainActor
    private static func replaceTranscript(
        with lines: [RetranscribedLine],
        in session: TranscriptionSession,
        context: ModelContext
    ) {
        // The old summary described a transcript that no longer exists.
        session.summaryParagraphs = []
        session.summaryKeyPoints = []
        session.shortDescription = nil
        for item in session.actionItems { context.delete(item) }

        // Replace every line (cascade delete stays on the session, which we keep).
        for line in session.lines { context.delete(line) }
        for draft in lines {
            let line = TranscriptionLine(
                text: draft.text,
                speakerId: draft.speakerId,
                speakerName: draft.speakerName,
                startMs: draft.startMs,
                endMs: draft.endMs,
                sourceAppBundleID: nil
            )
            line.session = session
            context.insert(line)
        }

        session.durationMs = lines.map(\.endMs).max() ?? session.durationMs
        session.previewText = TranscriptionSession.makePreviewText(from: lines.prefix(5).map(\.text))
        session.speakerNamesSummary = TranscriptionSession.makeSpeakerNamesSummary(from: session.lines)

        do {
            try context.save()
        } catch {
            print("❌ Re-transcribe: failed to save replaced transcript: \(error)")
        }

        // Rewrite the export against the new transcript. This is also what REMOVES
        // the now-stale `summary.md` — the summary was just cleared above, and a
        // session with no summary exports no summary file. Regeneration (when it
        // runs) exports again and brings it back.
        SessionExportCoordinator.export(session, context: context)
    }
}
