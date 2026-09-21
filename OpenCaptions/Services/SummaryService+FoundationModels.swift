//
//  SummaryService+FoundationModels.swift
//  OpenCaptions
//
//  The on-device summary transport: Apple's Foundation Models framework
//  (`LanguageModelSession` + guided generation), no network call, no API key. Sibling
//  to `SummaryService+OpenRouter.swift` — same `SummaryAPIResponse` shape out, so
//  everything downstream (`SummaryViewModel`, speaker auto-naming, markdown export)
//  is unaware which transport ran. See docs/2026-08-12-macos-foundation-models-summaries.md.
//
//  Reuses `SummaryService.systemInstruction(language:)` verbatim as the session's
//  instructions — no forked prompt. `@Generable`/`@Guide` are this framework's
//  equivalent of the JSON-schema-constrained response `SummaryService+Schema.swift`
//  already uses for OpenRouter; the field shapes mirror each other 1:1.
//
//  No truncation/chunking on a long transcript — the 4096-token context window
//  (instructions + transcript + output, combined) either fits or it doesn't. A
//  `LanguageModelSession.GenerationError.exceededContextWindowSize` (macOS 26) or
//  `LanguageModelError.contextSizeExceeded` (macOS 27+ — the type that superseded it)
//  becomes `SessionSummaryError.onDeviceContextExceeded`, which tells the user to
//  switch providers rather than silently returning a partial summary — and, where a
//  count is available, exactly how big the session was. Detecting both eras of that
//  error, and building that detail, live in `AppleIntelligenceContextWindow` — shared
//  with Chat's own on-device transport (`SessionChatService+FoundationModels`).
//

import Foundation
import FoundationModels

@available(macOS 26, *)
extension SummaryService {

    func callFoundationModelsAPI(transcript: String, language: String) async throws -> SummaryAPIResponse {
        let session = LanguageModelSession(instructions: Self.systemInstruction(language: language))
        do {
            let response = try await session.respond(to: transcript, generating: OnDeviceSummary.self)
            return response.content.asSummaryAPIResponse
        } catch {
            guard AppleIntelligenceContextWindow.isExceeded(error) else {
                throw SessionSummaryError.onDeviceUnavailable(error.localizedDescription)
            }
            throw SessionSummaryError.onDeviceContextExceeded(
                await AppleIntelligenceContextWindow.overflowDetail(for: error, text: transcript)
            )
        }
    }
}

// MARK: - Guided generation schema

/// Mirrors `SummaryAPIResponse` field-for-field. `@Guide` descriptions are ported from
/// `SummaryService+Schema.swift`'s own doc comments, not forked prose.
@available(macOS 26, *)
@Generable
private struct OnDeviceSummary {
    @Guide(description: "A short title, max 4 words, capturing the main topic.")
    var title: String

    @Guide(description: "A one-sentence summary of the transcript. Never starts with \"This\".")
    var shortDescription: String

    @Guide(description: "2-5 flowing-prose paragraphs, one per element, each covering a distinct topic or section.")
    var summary: [String]

    @Guide(description: "The key points from the transcript.")
    var keyPoints: [String]

    @Guide(description: "Commitments, dates, times, locations, amounts, and deadlines mentioned. Omitted when there are none.")
    var actionItems: [String]?

    @Guide(description: "One entry per diarized speaker id this transcript names — never a guess, and never an id with no \"Speaker N\" label in the transcript.")
    var speakers: [OnDeviceSpeakerIdentification]?
}

@available(macOS 26, *)
@Generable
private struct OnDeviceSpeakerIdentification {
    @Guide(description: "The numeric speaker id from the transcript's \"Speaker N\" labels.")
    var speakerId: Int

    @Guide(description: "Every plausible name for this speaker, each its own candidate with its own confidence — never chosen between.")
    var candidates: [OnDeviceSpeakerCandidate]?
}

@available(macOS 26, *)
@Generable
private struct OnDeviceSpeakerCandidate {
    @Guide(description: "The name exactly as spoken, first name only unless a surname was clearly stated.")
    var name: String

    @Guide(description: "0 to 1: how sure this name belongs to the speaker.")
    var confidence: Double
}

@available(macOS 26, *)
private extension OnDeviceSummary {
    var asSummaryAPIResponse: SummaryAPIResponse {
        SummaryAPIResponse(
            title: title,
            shortDescription: shortDescription,
            summary: summary,
            keyPoints: keyPoints,
            actionItems: actionItems,
            speakers: speakers.map { predictions in
                SpeakerPredictions(identifications: predictions.map { prediction in
                    SpeakerIdentification(
                        speakerId: prediction.speakerId,
                        candidates: prediction.candidates?.map {
                            SpeakerIdentification.Candidate(name: $0.name, confidence: $0.confidence)
                        }
                    )
                })
            }
        )
    }
}
