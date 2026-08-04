//
//  SummaryService+Schema.swift
//  OpenCaptions
//
//  The JSON Schema sent as `response_format.json_schema.schema` on the summary
//  request — the structured-output contract that shapes `SummaryAPIResponse`. Split
//  out of the transport file when the `speakers` array was added, to keep both under
//  the line limit.
//
//  Lowercase type names (`object`/`string`/`array`/`integer`/`number`) are the
//  standard JSON Schema spelling that OpenRouter's OpenAI-compatible API expects.
//  They were UPPERCASE while summaries went straight to Gemini's `v1beta` REST API,
//  which accepts only its own uppercase names — don't reintroduce those here.
//  `propertyOrdering` went with them: it is a Gemini extension with no OpenAI
//  equivalent, so field order is no longer pinned (nothing downstream depends on it).
//

import Foundation

extension SummaryService {

    /// Mirrors the `responseSchema` from the old `summarizeTranscript.ts`, plus the
    /// `speakers` array added for automatic speaker naming.
    ///
    /// `actionItems` and `speakers` are deliberately left out of `required` so both
    /// stay optional (matching `SummaryAPIResponse`) — a transcript with no action
    /// items, or with no identity signal to go on, simply omits them. This is why
    /// `additionalProperties: false` is absent too: the strict-mode convention of
    /// requiring every property would defeat that, and the pinned model's providers
    /// honor a partial `required` list as-is.
    ///
    /// Internal (not `private`) because `requestBody` reads it from
    /// `SummaryService+OpenRouter.swift` and Swift `private`/`fileprivate` don't
    /// cross files.
    static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "shortDescription": ["type": "string"],
            "summary": ["type": "array", "items": ["type": "string"]],
            "keyPoints": ["type": "array", "items": ["type": "string"]],
            "actionItems": ["type": "array", "items": ["type": "string"]],
            "speakers": speakersSchema
        ],
        "required": ["title", "shortDescription", "summary", "keyPoints"]
    ]

    /// One entry per diarized speaker the model could name, keyed by the numeric
    /// `speakerId` printed in the transcript it was given.
    ///
    /// `candidates` stays a list because a contested identity is a real outcome —
    /// the model reports every plausible name with its own confidence and
    /// `SpeakerNameResolver` applies the thresholds, so the model is never told what
    /// they are.
    private static let speakersSchema: [String: Any] = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "speakerId": ["type": "integer"],
                "candidates": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "confidence": ["type": "number"]
                        ],
                        "required": ["name", "confidence"]
                    ]
                ]
            ],
            "required": ["speakerId", "candidates"]
        ]
    ]
}
