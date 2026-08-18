# macOS: OpenRouter model picker, and a new "AI Models" Settings tab

**Date:** 2026-08-18 · **Scope:** Open Captions only · **Closes:** #58
**Related:** `docs/2026-08-04-macos-openrouter-summaries.md` (pinned the model this
unpicks — its "Model pinned" claim is now stale, see the banner added there),
`docs/2026-08-12-macos-foundation-models-summaries.md` (the `SummaryProviderKind`
picker this sits alongside, unaffected), `docs/2026-08-10-macos-settings-navsection.md`
(the Settings-as-`NavSection`/segmented-tab-switcher pattern this follows)

## Context

The OpenRouter summary transport pinned its model to a single hardcoded constant
(`deepseek/deepseek-v4-flash`, no picker — deliberate at the time, see the two docs
above). Users had no way to trade cost/quality/speed for a different model. Separately,
the "AI Models" section (Transcription Engine, Re-transcription Engine, Summary Model)
lived inside the General pane, nested under unrelated Session/Recording toggles; adding
a 4th picker here was the trigger to give it its own top-level Settings tab instead.

## Decision 1 — a curated, tiered, per-provider picker

The issue left the picker mechanism open: fetch OpenRouter's `/models` live, ship a
curated static list, or (a third option this note adds) a free-text field like the
existing API Key fields. Went with **curated static**, grouped by provider, tiered
where a provider ships one (Flagship / Standard / Lite / Budget): OpenAI (GPT-5.6 Sol /
Terra / Luna / GPT-5 Nano), Anthropic (Claude Opus 5 / Sonnet 5 / Haiku 4.5 — no Budget
tier, see below), Google (Gemini 3.1 Pro / 3.7 Flash / 3.5 Flash Lite / 3.1 Flash Lite),
DeepSeek (V4 Pro / V4 Flash — two tiers, already cheap enough that a third added no real
choice), Moonshot AI (Kimi K3 / K2.5), Mistral (Mistral Medium 3.5 / Small 3.2), and Qwen
(Qwen3.8 Max / Qwen3.5 Flash), plus xAI (Grok 4.6 — single tier, no distinctly cheaper
Grok exists in the current lineup). 20 models across 8 providers.

**`Budget` tiers exist for cost-conscious users**, added on top of the initial
Flagship/Standard/Lite pass after a follow-up request specifically calling out
`google/gemini-3.1-flash-lite` as an example of the kind of option missing. A `Budget`
pick is only added where it's *meaningfully* cheaper than that provider's existing
cheapest tier — not just marginally so:
- **Google** `.geminiBudget` → `gemini-3.1-flash-lite` (**$0.25/$1.50** per M tokens)
  is actually cheaper than `.geminiFlashLite` → `gemini-3.5-flash-lite`
  (**$0.30/$2.50**) despite being the older version — Google's newer "Lite" isn't
  always the cheaper one, which is exactly why this list is hand-curated rather than
  "always take the newest of each name."
- **OpenAI** `.gptNano` → `gpt-5-nano` (**$0.05/$0.40**) is ~4× cheaper than
  `.gptLuna` → `gpt-5.6-luna` (**$0.20/$1.20**).
- **Moonshot AI** `.kimiBudget` → `kimi-k2.5` (**$0.57/$2.85**) is ~5× cheaper than
  `.kimi` → `kimi-k3` (**$3.00/$15.00**).
- **Mistral** `.mistralBudget` → `mistral-small-3.2-24b-instruct` (**$0.094/$0.25**) is
  ~16× cheaper than `.mistral` → `mistral-medium-3.5` (**$1.50/$7.50**).
- **Qwen** `.qwenBudget` → `qwen3.5-flash-02-23` (**$0.065/$0.26**) is ~30× cheaper than
  `.qwen` → `qwen3.8-max` (**$2.00/$6.00**).

**Anthropic, DeepSeek, and xAI got no Budget tier** — not an oversight, a deliberate
skip: Anthropic's cheapest structured-output model already *is* `.claudeHaiku`, nothing
cheaper exists in its current lineup; DeepSeek's two tiers are already both under
$0.15/M tokens, so a third pick would be cost-noise, not real choice; xAI's older Grok
versions are only marginally (not meaningfully) cheaper than the current one.

**First pass of this feature used OpenRouter's own self-updating `"-latest"` aliases**
(e.g. `google/gemini-flash-latest`) instead of dated slugs, reasoning that a floating
pointer never goes stale. Reversed after review: a picker labeled just "Gemini Flash"
doesn't tell the user *which* Gemini, and an alias whose target silently changes
underneath a static label is worse than a dated slug that's simply correct today and
due for a refresh later — the whole point of this feature is letting the user see and
choose a specific model, not hand them an opaque floating pointer. So every `modelID`
in `OpenRouterModelKind` is now a **concrete, dated OpenRouter slug**, and `displayName`
names the exact model (`"Gemini 3.7 Flash · Standard"`, not `"Gemini Flash"`).

Every slug was verified directly against OpenRouter's own `/api/v1/models` endpoint
(not guessed) to confirm it exists and advertises `structured_outputs` — required
because `requestBody`'s `response_format` uses `strict: true` and
`provider.require_parameters: true`; a model that doesn't support strict schema
enforcement would make every summary fail outright, not degrade gracefully. This
assistant's own knowledge cutoff (2026-01) is seven months behind OpenRouter's live
catalog at time of writing, so nothing here was taken from memory alone.

**Accepted tradeoff:** being concrete dated slugs, this list is a point-in-time
snapshot — providers ship new tiers every few weeks (the OpenAI GPT-5.6 Sol/Terra/Luna
family itself superseded a 5.4 mini/nano naming scheme only ~4 months earlier), so
`OpenRouterModelKind` is expected to need occasional manual re-verification against the
same endpoint. This is the same tradeoff the single pinned model already lived with
before #58 — just now spread across fifteen options instead of one, and each option is
labeled with exactly what it is so a stale entry is at least identifiable (an unfamiliar
version number) rather than silently wrong.

A **live fetch** was rejected for the reason the issue itself called out: it would add
a network dependency (and a loading/error state) before Settings can even render the
picker, and would need the OpenRouter key already configured just to populate a
Settings screen. A **free-text field** (matching `MacAPIKeysSettingsView`'s API key
fields) was rejected because a typo only surfaces as a runtime error on the next
summary, with no discovery of what's even valid — worse UX than a bounded picker for
a decision most users will only make once in a while.

**Picker grouping:** `OpenRouterModelKind.Provider` (nested enum) drives a `Section`
per provider inside the `Picker`'s content — SwiftUI renders these as menu section
headers/dividers on macOS, so the picker reads as a grouped menu ("OpenAI ▸ GPT-5.6
Sol · Flagship / Terra · Standard / Luna · Lite", "Anthropic ▸ …") rather than a flat
15-item wall of names with no structure.

## Decision 2 — "AI Models" becomes its own Settings tab

`MacSettingsView`'s General pane previously carried the four AI-model pickers in an
`Section("AI Models")` block sandwiched inside `generalPane`, after the unrelated
Sessions section. Extracted into `MacAIModelsSettingsView` (new file) with its own
segmented-tab entry (`sparkles` icon, positioned right after General), following the
same per-pane-file convention as `MacHotKeysSettingsView` / `MacSupportSettingsView` /
`MacAPIKeysSettingsView`. `MacSettingsView+Retranscription.swift` moved with it,
renamed `MacAIModelsSettingsView+Retranscription.swift`, its extension retargeted.

One wrinkle: `MacSettingsView`'s Sessions section still has a speaker-naming toggle
that's disabled for an on-device transcription engine (`isOffline`), so it still needs
to read `transcriptionEngineKindKey` — moving the *picker* to the new pane didn't move
that dependency. Fixed by having `MacSettingsView` keep its own
`@AppStorage(LiveSessionStore.transcriptionEngineKindKey)` alongside
`MacAIModelsSettingsView`'s — both bind the same UserDefaults key, and SwiftUI's
`@AppStorage` update propagation makes that the correct pattern here, not a duplication
bug: either view changing the value is reflected in the other automatically.

## Storage

`OpenRouterModelKind: String, CaseIterable, Identifiable` (new,
`Services/OpenRouterModelKind.swift`), mirroring `SummaryProviderKind`'s shape, plus a
nested `Provider` enum purely for picker grouping (`provider.models` filters
`allCases`). Persisted via a new `LiveSessionStore.openRouterModelKindKey`
(`LiveSessionStore+OpenRouterModel.swift`, new file, same pattern as
`LiveSessionStore+SummaryProvider.swift`), default `.deepseekFlash` — the same
DeepSeek V4 Flash model the app pinned before #58 — registered in `OpenCaptionsApp`
alongside the other AI-model defaults. `SummaryService+OpenRouter.requestBody` now
reads `LiveSessionStore.openRouterModelKind.modelID` for the `"model"` field instead of
the deleted `model` constant.

The picker row itself is only shown when `summaryProvider == .openRouter` — it's
meaningless for `.foundationModels`, which has no OpenRouter transport at all.
