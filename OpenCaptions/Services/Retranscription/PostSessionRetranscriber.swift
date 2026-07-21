//
//  PostSessionRetranscriber.swift
//  OpenCaptions
//
//  The shared core for post-session re-transcription: runs a chosen engine over a
//  saved recording, replaces the session transcript, meters a cloud engine, and
//  regenerates the summary. Driven by `RetranscriptionManager` for BOTH the manual and
//  automatic paths, so the two can never diverge.
//  See issue #245 and docs/2026-07-16-macos-post-session-retranscription.md.
//

import AVFoundation
import Foundation
import SwiftData

enum PostSessionRetranscriber {

    /// Runs `kind` over `audioURL` and applies the result to `session`.
    ///
    /// - Throws: `PostSessionEngineError` on failure, `CancellationError` if cancelled.
    ///   Holds the billing metered window across a cloud run so a concurrent
    ///   foreground refresh can't double-flush the pending deduction.
    @MainActor
    static func run(
        kind: RetranscriptionEngineKind,
        session: TranscriptionSession,
        audioURL: URL,
        context: ModelContext,
        userName: String?,
        progress: @escaping @MainActor (PostSessionProgress) -> Void
    ) async throws {
        let billing = MacSubscriptionManager.shared
        if kind.isMetered { billing.beginMeteredWindow() }
        defer { if kind.isMetered { billing.endMeteredWindow() } }

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

        // Meter the cloud engine by the recording's duration (ceil to whole minutes),
        // matching how a live cloud session is billed.
        if kind.isMetered {
            let minutes = Int(ceil(await audioDurationSeconds(audioURL) / 60.0))
            await billing.chargeMinutes(minutes)
        }

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

    // MARK: - Duration

    /// The recording's duration in seconds (for billing + the up-front affordability
    /// gate), or 0 if unreadable. Internal so the manager can size the cost gate.
    static func audioDurationSeconds(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}
