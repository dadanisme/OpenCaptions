//
//  SummaryService+Schema.swift
//  OpenCaptions
//
//  The Gemini `generationConfig.responseSchema` for the summary request — the
//  structured-output contract that shapes `SummaryAPIResponse`. Split out of
//  `SummaryService+Gemini` (which owns the transport) when the `speakers` array
//  was added, to keep both files under the line limit.
//
//  Uppercase REST type names (`OBJECT`/`STRING`/`ARRAY`/`INTEGER`/`NUMBER`) are
//  what the `v1beta` REST API expects — not the lowercase JSON Schema spelling.
//

import Foundation

extension SummaryService {

    /// Mirrors the `responseSchema` from the old `summarizeTranscript.ts`, plus the
    /// `speakers` array added for automatic speaker naming.
    ///
    /// `actionItems` and `speakers` are deliberately left out of `required` so both
    /// stay optional (matching `SummaryAPIResponse`) — a transcript with no action
    /// items, or with no identity signal to go on, simply omits them.
    /// `propertyOrdering` keeps the generated field order stable.
    ///
    /// Internal (not `private`) because `requestBody` reads it from
    /// `SummaryService+Gemini.swift` and Swift `private`/`fileprivate` don't cross
    /// files.
    static let responseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "title": ["type": "STRING"],
            "shortDescription": ["type": "STRING"],
            "summary": ["type": "ARRAY", "items": ["type": "STRING"]],
            "keyPoints": ["type": "ARRAY", "items": ["type": "STRING"]],
            "actionItems": ["type": "ARRAY", "items": ["type": "STRING"]],
            "speakers": speakersSchema
        ],
        "required": ["title", "shortDescription", "summary", "keyPoints"],
        "propertyOrdering": [
            "title", "shortDescription", "summary", "keyPoints", "actionItems", "speakers"
        ]
    ]

    /// One entry per diarized speaker the model could name, keyed by the numeric
    /// `speakerId` printed in the transcript it was given.
    ///
    /// `candidates` stays a list because a contested identity is a real outcome —
    /// the model reports every plausible name with its own confidence and
    /// `SpeakerNameResolver` applies the thresholds, so the model is never told what
    /// they are.
    private static let speakersSchema: [String: Any] = [
        "type": "ARRAY",
        "items": [
            "type": "OBJECT",
            "properties": [
                "speakerId": ["type": "INTEGER"],
                "candidates": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "name": ["type": "STRING"],
                            "confidence": ["type": "NUMBER"]
                        ],
                        "required": ["name", "confidence"],
                        "propertyOrdering": ["name", "confidence"]
                    ]
                ]
            ],
            "required": ["speakerId", "candidates"],
            "propertyOrdering": ["speakerId", "candidates"]
        ]
    ]
}
