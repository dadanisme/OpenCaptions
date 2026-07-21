//
//  TranscriptionSession+Derived.swift
//  unmute
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

    /// Recomputes and stores the derived fields by scanning `lines`.
    /// Used by the one-time launch backfill for legacy sessions.
    func recomputeDerivedFields() {
        durationMs = scannedDurationMs
        previewText = scannedPreviewText
    }

    /// Builds the cached card preview from the first few line texts.
    static func makePreviewText(from texts: [String]) -> String {
        texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
}
