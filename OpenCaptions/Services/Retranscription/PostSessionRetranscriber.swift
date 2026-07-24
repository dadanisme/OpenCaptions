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

        // If this session is shared to the web, re-push the new transcript to the SAME
        // link so the web copy doesn't go stale (no-op when unshared / sharing off).
        // Summary is re-mirrored below by regeneration, or left cleared offline.
        SessionLinkSharer.resyncShared(session: session)

        // Regenerate the summary from the fresh transcript. It's a cloud call, so skip
        // it in Offline Mode — the (now-cleared) summary can be generated later.
        if !UserDefaults.standard.bool(forKey: LiveSessionStore.offlineModeKey) {
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

        do {
            try context.save()
        } catch {
            print("❌ Re-transcribe: failed to save replaced transcript: \(error)")
        }
    }
}
