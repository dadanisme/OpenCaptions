//
//  LiveSessionStore+SummaryProvider.swift
//  OpenCaptions
//
//  The two-way summary provider selection (OpenRouter / Apple Foundation Models) —
//  the global Settings preference read by `SummaryService.summarize` and by every
//  summary-availability gate. See docs/2026-08-12-macos-foundation-models-summaries.md.
//

import Foundation

extension LiveSessionStore {

    /// UserDefaults key (String) for the two-way summary provider selection —
    /// `SummaryProviderKind.rawValue`. Read by `SummaryService.summarize` to pick the
    /// transport, and by every summary-availability gate (auto-summarize, Re-summarize,
    /// the Summary tab empty state, post-retranscription regen). Bound to the picker in
    /// Settings → General. Default `"openRouter"` (registered in `OpenCaptionsApp`).
    /// `nonisolated` so it can be read from non-MainActor contexts, matching
    /// `transcriptionEngineKindKey`'s own reasoning.
    nonisolated static let summaryProviderKindKey = "opencaptions.summaryProvider.kind"

    /// The current two-way summary provider selection, decoded from
    /// `summaryProviderKindKey`. Falls back to `.openRouter` for an unset/invalid raw
    /// value, matching the registered default.
    nonisolated static var summaryProviderKind: SummaryProviderKind {
        SummaryProviderKind(
            rawValue: UserDefaults.standard.string(forKey: summaryProviderKindKey) ?? ""
        ) ?? .openRouter
    }
}
