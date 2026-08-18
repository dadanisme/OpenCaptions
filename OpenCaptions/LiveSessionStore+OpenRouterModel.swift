//
//  LiveSessionStore+OpenRouterModel.swift
//  OpenCaptions
//
//  The OpenRouter model selection for AI summaries (#58) — the global Settings
//  preference read by `SummaryService+OpenRouter.requestBody` to fill the
//  request's `"model"` field. Independent of `summaryProviderKindKey`: this
//  only matters when that picker is set to `.openRouter`. See
//  docs/2026-08-18-macos-openrouter-model-picker.md.
//

import Foundation

extension LiveSessionStore {

    /// UserDefaults key (String) for the OpenRouter model selection —
    /// `OpenRouterModelKind.rawValue`. Bound to the picker in Settings → AI
    /// Models. Default `"deepseekFlash"` (registered in `OpenCaptionsApp`),
    /// matching the model this app pinned before #58 added the picker.
    /// `nonisolated` so it can be read from non-MainActor contexts, matching
    /// `summaryProviderKindKey`'s own reasoning.
    nonisolated static let openRouterModelKindKey = "opencaptions.openRouterModel.kind"

    /// The current OpenRouter model selection, decoded from
    /// `openRouterModelKindKey`. Falls back to `.deepseekFlash` for an
    /// unset/invalid raw value, matching the registered default.
    nonisolated static var openRouterModelKind: OpenRouterModelKind {
        OpenRouterModelKind(
            rawValue: UserDefaults.standard.string(forKey: openRouterModelKindKey) ?? ""
        ) ?? .deepseekFlash
    }
}
