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
//  count is available (see `contextOverflowDetail`), exactly how big the session was.
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
            guard isContextWindowExceeded(error) else {
                throw SessionSummaryError.onDeviceUnavailable(error.localizedDescription)
            }
            throw SessionSummaryError.onDeviceContextExceeded(
                await contextOverflowDetail(for: error, transcript: transcript)
            )
        }
    }

    /// Checks both eras of the framework's context-overflow error: `LanguageModelError`
    /// (macOS 27+) and the `LanguageModelSession.GenerationError` it superseded. The
    /// latter is still what an exact-macOS-26 runtime throws — `LanguageModelError`
    /// itself didn't exist before 27 — so it has to stay checked as long as this
    /// feature's own floor is macOS 26, not 27.
    private func isContextWindowExceeded(_ error: Error) -> Bool {
        if #available(macOS 27, *), let languageModelError = error as? LanguageModelError,
           case .contextSizeExceeded = languageModelError {
            return true
        }
        return isLegacyContextWindowExceeded(error)
    }

    /// Isolates the one intentionally-deprecated reference in this file: checked only
    /// because `LanguageModelSession.GenerationError` — deprecated in macOS 27 in favor
    /// of `LanguageModelError` — is still the only type an exact-macOS-26 runtime can
    /// throw for this. Marking this function itself deprecated for the same version
    /// suppresses the warning that referencing it would otherwise raise.
    @available(macOS, deprecated: 27.0, message: "Intentionally still checked — see call site.")
    private func isLegacyContextWindowExceeded(_ error: Error) -> Bool {
        guard let generationError = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = generationError { return true }
        return false
    }

    /// A user-facing "how big was this" detail for `.onDeviceContextExceeded`, e.g.
    /// "5,412 tokens, over the 4,096-token on-device limit". Two sources, in
    /// preference order:
    ///
    /// 1. **macOS 27+**: `LanguageModelError.contextSizeExceeded` already carries the
    ///    exact measured `tokenCount` and `contextSize` for the attempt that just
    ///    failed — no extra work needed.
    /// 2. **macOS 26.4–26.x**: the deprecated `GenerationError` this OS range throws
    ///    instead carries no structured numbers (just a debug string), so this
    ///    independently measures the transcript alone via the model's own tokenizer
    ///    (`SystemLanguageModel.tokenCount(for:)`, itself only available from 26.4).
    ///    No `contextSize` to report here — only the transcript's own count.
    ///
    /// Below macOS 26.4, neither source exists; callers get `nil` and fall back to
    /// the plain, count-less copy.
    private func contextOverflowDetail(for error: Error, transcript: String) async -> String? {
        if #available(macOS 27, *), let languageModelError = error as? LanguageModelError,
           case .contextSizeExceeded(let details) = languageModelError {
            return "\(details.tokenCount.formatted()) tokens, over the \(details.contextSize.formatted())-token on-device limit"
        }
        guard #available(macOS 26.4, *) else { return nil }
        guard let tokenCount = try? await SystemLanguageModel.default.tokenCount(for: transcript) else { return nil }
        return "\(tokenCount.formatted()) tokens in this session"
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
