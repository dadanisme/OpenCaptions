//
//  SummaryViewModel.swift
//  OpenCaptions
//

import SwiftUI
import SwiftData

@MainActor
@Observable
final class SummaryViewModel {
    var isLoading = false
    var errorMessage: String?

    private let service = SummaryService()

    func generateSummary(session: TranscriptionSession, context: ModelContext) async {
        guard !session.lines.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await service.summarize(session: session)
            service.saveStructuredSummary(response, to: session, context: context)
            session.sessionTitle = response.title
            session.shortDescription = response.shortDescription
            try? context.save()

            // Auto-name the diarized speakers the model was confident about. Silent
            // and best-effort: no-op when it named nobody (or named nobody
            // confidently enough), and it never affects whether the summary saved.
            // Edit Speakers remains the correction path.
            SpeakerRenamer.apply(
                SpeakerNameResolver.resolve(response.identifiedSpeakers),
                to: session,
                context: context
            )

            // If this session is shared, mirror the fresh summary to the web view
            // so it matches the app (no-op when sharing is off / session unshared).
            FirestoreSyncService.shared.writeSummary(
                cloudSessionId: session.cloudSessionId,
                paragraphs: session.summaryParagraphs,
                keyPoints: session.summaryKeyPoints,
                actionItems: session.actionItems
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map(\.text),
                title: session.sessionTitle,
                shortDescription: session.shortDescription ?? ""
            )
        } catch {
            if let e = error as? LocalizedError, let desc = e.errorDescription {
                errorMessage = desc
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
