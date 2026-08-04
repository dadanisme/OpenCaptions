//
//  TranscriptionSession+Derived.swift
//  OpenCaptions
//
//  Cached derived fields (`durationMs`, `previewText`) keep list cards O(1).
//  See docs/2026-06-02-home-screen-derived-fields.md for the design decision.
//

import Foundation

extension TranscriptionSession {
    /// Duration in ms, preferring the cached field. Falls back to scanning
    /// `lines` (O(n)) only for legacy rows that the launch backfill has not
    /// reached yet.
    var resolvedDurationMs: Int {
        durationMs ?? scannedDurationMs
    }

    /// Card preview text, preferring the cached field. Falls back to
    /// sorting/scanning `lines` (O(n log n)) only for legacy rows.
    var resolvedPreviewText: String {
        previewText ?? scannedPreviewText
    }

    /// Speaker-names row summary, preferring the cached field. Falls back to
    /// scanning `lines` (O(n)) only for legacy rows.
    var resolvedSpeakerNamesSummary: String {
        speakerNamesSummary ?? scannedSpeakerNamesSummary
    }

    /// Recomputes and stores the derived fields by scanning `lines`.
    /// Used by the one-time launch backfill for legacy sessions.
    func recomputeDerivedFields() {
        durationMs = scannedDurationMs
        previewText = scannedPreviewText
        speakerNamesSummary = scannedSpeakerNamesSummary
    }

    /// Builds the cached card preview from the first few line texts.
    static func makePreviewText(from texts: [String]) -> String {
        texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the cached "who was in this session" row summary (e.g.
    /// "Yoga, Abby, and 2 more"). Prefers named speakers over generic
    /// "Speaker N" placeholders when picking which two names to show — see
    /// docs/2026-08-04-session-list-speaker-names.md for the truncation rule.
    static func makeSpeakerNamesSummary(from lines: [TranscriptionLine]) -> String {
        let speakers = SpeakerLabel.distinctSpeakers(from: lines)
        guard !speakers.isEmpty else { return "" }
        if speakers.count == 1 { return speakers[0].name }
        if speakers.count == 2 { return "\(speakers[0].name) and \(speakers[1].name)" }
        let named = speakers.filter { !SpeakerLabel.isDefault($0.name, id: $0.id) }
        let generic = speakers.filter { SpeakerLabel.isDefault($0.name, id: $0.id) }
        let shown = Array((named + generic).prefix(2))
        let remaining = speakers.count - shown.count
        return "\(shown.map(\.name).joined(separator: ", ")), and \(remaining) more"
    }

    // MARK: - Full Scans (legacy rows only)

    private var scannedDurationMs: Int {
        var minMs: Int?
        var maxMs: Int?
        for line in lines where line.startMs >= 0 && line.endMs >= 0 {
            minMs = min(minMs ?? line.startMs, line.startMs)
            maxMs = max(maxMs ?? line.endMs, line.endMs)
        }
        guard let minMs, let maxMs else { return 0 }
        return max(0, maxMs - minMs)
    }

    private var scannedPreviewText: String {
        let firstLines = lines
            .sorted { $0.timestamp < $1.timestamp }
            .prefix(5)
            .map(\.text)
        return Self.makePreviewText(from: firstLines)
    }

    private var scannedSpeakerNamesSummary: String {
        Self.makeSpeakerNamesSummary(from: lines)
    }
}
