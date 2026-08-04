# macOS: AI summaries move from the direct Gemini call to OpenRouter

**Date:** 2026-08-04 · **Scope:** Open Captions only · **Closes:** #29
**Related:** `docs/2026-07-24-macos-native-gemini-summary.md` (**the transport this
replaces** — now historical), `docs/2026-07-29-macos-speaker-auto-naming.md` (rides on
the same response), `docs/2026-07-10-macos-offline-mode.md` (the offline gate, untouched)

## Context

Summaries POSTed straight to Google's `generateContent` endpoint. That worked, but the
transport had **no retry and no failover**, and Gemini's public API returns overload
errors — `503 UNAVAILABLE` / `429 RESOURCE_EXHAUSTED` — often enough to be a real
annoyance. An overloaded upstream fell into the `default` branch of the status switch
and failed the whole summary with a raw `Server error: …`. The user's only recourse was
to hit Re-summarize and hope.

OpenRouter fronts **several upstream providers for the same model**, so a saturated one
can be routed around rather than surfaced as a failure. That is the entire motivation;
everything else here is a consequence of the wire format changing.

## Decision

**Full replacement.** The direct Gemini transport is deleted, not kept as a fallback.
No provider abstraction, no runtime switch — one path is easier to reason about than a
two-provider matrix whose second branch is never exercised.

**Model pinned to `google/gemini-3.1-flash-lite`**, no user-facing picker. Verified
against OpenRouter's model list before wiring: it advertises `structured_outputs` and
`response_format`, and is served by **six endpoints across Google Vertex and Google AI
Studio** — which is what makes provider fallback more than a decoration. A picker would
mean persisting a preference, validating that the chosen model supports structured
output, and a Settings surface; out of scope.

**Key stays build-time**, following `GEMINI_API_KEY` exactly:
`Config.xcconfig` → `OpenCaptions-Info.plist` → `Bundle.main.infoDictionary`. Both
plumbing steps are required — a key in the xcconfig alone never reaches
`infoDictionary` and reads back `nil` at runtime.

## Overload handling — two mechanisms, both load-bearing

A straight port that still hard-fails on 503 would not have closed the issue, so
overload is handled twice over:

1. **Provider fallback.** `provider: {allow_fallbacks: true, require_parameters: true}`.
   `require_parameters` is the non-obvious half: without it OpenRouter may fall back to
   an endpoint that *ignores* `response_format`, which would return prose and fail
   decoding — a worse outcome than the 503 it avoided.
2. **Bounded retry.** `408 / 429 / 502 / 503` are retried twice, backoff 1 s → 4 s,
   honoring a `Retry-After` header when present but **clamped to 10 s** so a long
   server-suggested wait can't stall an interactive summary. Three attempts total, so
   the worst case adds ~5 s before the user sees an error instead of hanging on an
   outage.

Only when all three attempts come back busy does it throw the new
`SessionSummaryError.overloaded`, whose copy is actionable ("Every summary provider is
busy right now. Try Re-summarize in a moment.") rather than a raw HTTP message.

## What changed on the wire

| Gemini | OpenRouter |
|---|---|
| `…/models/gemini-2.5-flash-lite:generateContent` | `https://openrouter.ai/api/v1/chat/completions` |
| `x-goog-api-key: <key>` | `Authorization: Bearer <key>` |
| `systemInstruction.parts[].text` | `messages[0]`, `role: "system"` |
| `contents[].parts[].text` | `messages[1]`, `role: "user"` |
| `generationConfig.responseSchema` | `response_format.json_schema.schema` |
| `candidates[0].content.parts[0].text` | `choices[0].message.content` |
| uppercase `OBJECT`/`STRING`/`ARRAY` | lowercase `object`/`string`/`array` |
| `propertyOrdering` | *(dropped — no equivalent)* |

The key stays out of the URL in both, as before.

## Traps worth knowing

- **Schema type-name casing is provider-specific and silent.** Gemini's `v1beta` REST
  API accepts *only* `OBJECT`/`STRING`/`ARRAY`; standard JSON Schema (and therefore
  OpenRouter's OpenAI-compatible API) wants them lowercase. Neither rejects the other's
  spelling in a way that names the real problem, so this is worth a comment in
  `SummaryService+Schema.swift` — and there is one.
- **`propertyOrdering` is gone**, so generated field order is no longer pinned. Nothing
  downstream depended on it: `SummaryAPIResponse` is decoded by key.
- **Two decoders, deliberately.** The envelope is snake_case (`finish_reason`,
  `native_finish_reason`) and uses `.convertFromSnakeCase`. The summary JSON *inside*
  `choices[0].message.content` is camelCase (`shortDescription`, `keyPoints`,
  `speakerId`) and must use a **plain** decoder. Reusing the converting decoder for
  both would break every multi-word field.
- **A 200 is not proof of success.** OpenRouter reports a mid-generation upstream
  failure in the body's `error`, and truncation / filtering in
  `choices[0].finish_reason`. Both are checked, and both produce specific copy —
  `length` says the transcript may be too long, `content_filter` says it was blocked —
  so an incomplete generation never reads as a decoding bug.
- **`strict: true` without `additionalProperties: false`.** The strict-mode convention
  of requiring every property would defeat the deliberate optionality of `actionItems`
  and `speakers`, and "the model named nobody" is the *correct* answer for a transcript
  with no identity signal. The pinned model's providers honor a partial `required` list
  as-is.
- **The 400-sniffing hack is gone.** Gemini reported a bad or placeholder key as
  `400 INVALID_ARGUMENT`, which forced `isAPIKeyError` to pattern-match the message
  text. OpenRouter returns a genuine `401`, so the mapping is now structural. `402`
  (out of credits) gets its own case too — it is the other misconfiguration a
  bring-your-own-key setup actually hits.
- **A fenced response is tolerated.** `response_format: json_schema` should yield bare
  JSON, but reasoning models occasionally wrap it in a ``` fence. Stripping one is
  cheaper than failing an otherwise good summary.

## Files

- **New** `Services/SummaryService+OpenRouter.swift` — endpoint, model, auth, request
  body, send + retry, status → error mapping.
- **New** `Services/SummaryService+OpenRouterResponse.swift` — DTOs, `decodeSummary`,
  `errorMessage`, finish-reason copy. Split from the transport to stay under the
  ~250-line target; both entry points are `static` + internal because Swift `private`
  doesn't cross files.
- **Deleted** `Services/SummaryService+Gemini.swift`.
- `Services/SummaryService+Schema.swift` — lowercase type names, `propertyOrdering`
  dropped, header rewritten.
- `Services/SummaryService.swift` — `.overloaded` / `.insufficientCredits` added,
  `.unauthorized` copy now names `OPENROUTER_API_KEY`.
- `Services/SummaryService+Prompt.swift` — header no longer says "Gemini"; the prompt
  text is unchanged and portable. The `ogmo-cf/summarizeTranscript.ts` provenance
  comment is retained, as is its twin in the new transport file.
- `Config.xcconfig.example`, `OpenCaptions-Info.plist` — `GEMINI_API_KEY` →
  `OPENROUTER_API_KEY`.
- Comment-only: `LiveSessionStore.swift`, `ConversationFormatter.swift`,
  `Speakers/SpeakerIdentification.swift`. Docs: `CLAUDE.md`, `README.md`.

## Unchanged on purpose

`SummaryAPIResponse` is untouched, so `SummaryViewModel`, `saveStructuredSummary`, the
Firestore mirror, the ActionItems / KeyPoints screens, `SpeakerNameResolver`, and
`SpeakerRenamer` all needed no edit. The prompt — including the SPEAKER IDENTIFICATION
section and its evidence rules — is byte-identical, and the resolver's `0.85` / `0.35`
thresholds still live only in `Services/Speakers/`.

The **offline-mode gates are untouched.** All four still read the global
`offlineModeKey`, so an offline-captured session can still be summarized later by
turning the toggle off, and a guest is still locked out of summaries entirely.

## Follow-ups not taken

- **No `reasoning_effort` / `max_tokens`.** Left at provider defaults. Gemini 3.x
  models support a reasoning budget, so `reasoning: {effort: "low"}` is the obvious
  latency knob for auto-summarize if summaries feel slow — but it is a quality
  trade-off, not a migration requirement.
- **No model picker, no per-user key.** Both would need a Settings surface and
  validation; the issue explicitly scoped them out.

## Verification

Manual, in Xcode, with a real `OPENROUTER_API_KEY` in `Config.xcconfig` (there are no
unit tests in this project):

1. Stop & Save a diarized multi-speaker session → auto-summary populates title, short
   description, paragraphs, key points, action items; confidently-named speakers are
   renamed and `summary.md` appears in the export folder.
2. Re-summarize on an existing session → same, and the Firestore mirror updates for a
   shared session.
3. Empty / placeholder key → "Unauthorized — check that OPENROUTER_API_KEY…", no crash.
4. Offline Mode on → the Summary tab's offline empty state, Re-summarize disabled; turn
   it off and the same session summarizes.
