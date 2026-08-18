//
//  OpenRouterModelKind.swift
//  OpenCaptions
//
//  The user-selectable OpenRouter model for AI summaries (#58) — read by
//  `SummaryService+OpenRouter.requestBody` for the request's `"model"` field.
//  Only meaningful when `SummaryProviderKind` is `.openRouter`.
//
//  Tiered per provider (Flagship/Standard/Lite/Budget, as many as that
//  provider's OpenRouter catalog actually supports — not every provider has
//  all four) so the Settings picker shows specific, named models — never a
//  bare "<Provider> Flash" with no version — grouped under a `Section` per
//  provider so the picker reads as a menu, not a flat wall of names. `Budget`
//  cases exist specifically for cost-conscious users: a meaningfully cheaper
//  (not just marginally cheaper) alternative to that provider's `Lite`/
//  `Standard` pick, e.g. `.geminiBudget` (Gemini 3.1 Flash Lite) is ~20%
//  cheaper per token than `.geminiFlashLite` (Gemini 3.5 Flash Lite,
//  ordinarily the cheaper-sounding name — the newer "Lite" isn't always the
//  cheaper one, which is why this is a curated list rather than "always pick
//  the newest").
//
//  Every `modelID` below is a concrete, dated OpenRouter slug (not a floating
//  "-latest" alias) verified directly against OpenRouter's `/api/v1/models`
//  listing on 2026-08-18 to advertise `structured_outputs`, which
//  `requestBody`'s `strict: true` response format depends on — a model
//  without that support would make every summary fail outright, not degrade
//  gracefully. Being concrete slugs, this list is a point-in-time snapshot:
//  providers ship new tiers every few weeks, so this enum is expected to need
//  occasional manual refreshes against the same endpoint, same as the single
//  model this app pinned before #58. See
//  docs/2026-08-18-macos-openrouter-model-picker.md.
//

import Foundation

/// A user-selectable OpenRouter model for AI summaries.
enum OpenRouterModelKind: String, CaseIterable, Identifiable {
    // OpenAI — GPT-5.6 family, + GPT-5 Nano for a cost-conscious pick
    case gptSol
    case gptTerra
    case gptLuna
    case gptNano
    // Anthropic — Claude 5 family (no meaningfully-cheaper-than-Haiku option
    // exists in Anthropic's current structured-output lineup, so no Budget tier)
    case claudeOpus
    case claudeSonnet
    case claudeHaiku
    // Google — Gemini family
    case geminiPro
    case geminiFlash
    case geminiFlashLite
    case geminiBudget
    // DeepSeek — V4 family (already the cheapest lineup here; no Budget tier
    // needed on top of an already sub-$0.15/M-token Lite pick)
    case deepseekPro
    case deepseekFlash
    // xAI (single tier — no distinctly cheaper Grok exists in this lineup)
    case grok
    // Moonshot AI
    case kimi
    case kimiBudget
    // Mistral
    case mistral
    case mistralBudget
    // Qwen
    case qwen
    case qwenBudget

    var id: String { rawValue }

    /// Which `Provider` group this belongs to — drives the picker's `Section` grouping.
    var provider: Provider {
        switch self {
        case .gptSol, .gptTerra, .gptLuna, .gptNano: return .openAI
        case .claudeOpus, .claudeSonnet, .claudeHaiku: return .anthropic
        case .geminiPro, .geminiFlash, .geminiFlashLite, .geminiBudget: return .google
        case .deepseekPro, .deepseekFlash: return .deepSeek
        case .grok: return .xAI
        case .kimi, .kimiBudget: return .moonshotAI
        case .mistral, .mistralBudget: return .mistral
        case .qwen, .qwenBudget: return .qwen
        }
    }

    /// The literal OpenRouter model slug sent as `requestBody`'s `"model"` value.
    var modelID: String {
        switch self {
        case .gptSol: return "openai/gpt-5.6-sol"
        case .gptTerra: return "openai/gpt-5.6-terra"
        case .gptLuna: return "openai/gpt-5.6-luna"
        case .gptNano: return "openai/gpt-5-nano"
        case .claudeOpus: return "anthropic/claude-opus-5"
        case .claudeSonnet: return "anthropic/claude-sonnet-5"
        case .claudeHaiku: return "anthropic/claude-haiku-4.5"
        case .geminiPro: return "google/gemini-3.1-pro-preview"
        case .geminiFlash: return "google/gemini-3.7-flash"
        case .geminiFlashLite: return "google/gemini-3.5-flash-lite"
        case .geminiBudget: return "google/gemini-3.1-flash-lite"
        case .deepseekPro: return "deepseek/deepseek-v4-pro-0813"
        case .deepseekFlash: return "deepseek/deepseek-v4-flash-0731"
        case .grok: return "x-ai/grok-4.6"
        case .kimi: return "moonshotai/kimi-k3"
        case .kimiBudget: return "moonshotai/kimi-k2.5"
        case .mistral: return "mistralai/mistral-medium-3-5"
        case .mistralBudget: return "mistralai/mistral-small-3.2-24b-instruct"
        case .qwen: return "qwen/qwen3.8-max"
        case .qwenBudget: return "qwen/qwen3.5-flash-02-23"
        }
    }

    /// Label for the Settings picker — the specific model name, plus a tier
    /// qualifier for providers that ship more than one (the provider itself is
    /// implied by the enclosing `Section`, so it isn't repeated here).
    var displayName: String {
        switch self {
        case .gptSol: return "GPT-5.6 Sol · Flagship"
        case .gptTerra: return "GPT-5.6 Terra · Standard"
        case .gptLuna: return "GPT-5.6 Luna · Lite"
        case .gptNano: return "GPT-5 Nano · Budget"
        case .claudeOpus: return "Claude Opus 5 · Flagship"
        case .claudeSonnet: return "Claude Sonnet 5 · Standard"
        case .claudeHaiku: return "Claude Haiku 4.5 · Lite"
        case .geminiPro: return "Gemini 3.1 Pro · Flagship"
        case .geminiFlash: return "Gemini 3.7 Flash · Standard"
        case .geminiFlashLite: return "Gemini 3.5 Flash Lite · Lite"
        case .geminiBudget: return "Gemini 3.1 Flash Lite · Budget"
        case .deepseekPro: return "DeepSeek V4 Pro · Standard"
        case .deepseekFlash: return "DeepSeek V4 Flash · Lite"
        case .grok: return "Grok 4.6"
        case .kimi: return "Kimi K3 · Standard"
        case .kimiBudget: return "Kimi K2.5 · Budget"
        case .mistral: return "Mistral Medium 3.5 · Standard"
        case .mistralBudget: return "Mistral Small 3.2 · Budget"
        case .qwen: return "Qwen3.8 Max · Standard"
        case .qwenBudget: return "Qwen3.5 Flash · Budget"
        }
    }

    /// The provider groups the Settings picker sections its models under.
    enum Provider: String, CaseIterable, Identifiable {
        case openAI, anthropic, google, deepSeek, xAI, moonshotAI, mistral, qwen

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .google: return "Google"
            case .deepSeek: return "DeepSeek"
            case .xAI: return "xAI"
            case .moonshotAI: return "Moonshot AI"
            case .mistral: return "Mistral"
            case .qwen: return "Qwen"
            }
        }

        /// This provider's models, in picker display order.
        var models: [OpenRouterModelKind] {
            OpenRouterModelKind.allCases.filter { $0.provider == self }
        }
    }
}
