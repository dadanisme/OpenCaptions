# macOS: Native Gemini summary service (backend-less AI summaries)

> **⚠️ HISTORICAL — superseded 2026-08-04.** The *transport* described below (a
> direct call to Google's `generateContent` REST endpoint with a `GEMINI_API_KEY`
> in an `x-goog-api-key` header) no longer exists; summaries now go through
> OpenRouter. See **`docs/2026-08-04-macos-openrouter-summaries.md`**. What this
> note still documents accurately: *why* summaries are backend-less at all, the
> prompt's provenance in `ogmo-cf/summarizeTranscript.ts`, and the
> `SummaryAPIResponse` contract — none of which the migration changed.

**Date:** 2026-07-24 · **Scope:** Open Captions only · **Closes:** #3
**Related:** `docs/2026-07-10-macos-offline-mode.md` (the offline gate),
`docs/2026-07-12-macos-consolidated-action-items.md` (a downstream consumer),
`docs/2026-08-04-macos-openrouter-summaries.md` (**supersedes the transport**)

## Context

Decoupling from the legacy Ogmo backend (commit `e2eb281`) removed the
`SUMMARIZE_URL` Cloud Function, so `SummaryService` had **no endpoint** — every
summary attempt failed gracefully with "Summaries are unavailable". This change
re-implements summarization **natively in Swift by calling the Google Gemini
`generateContent` REST API directly** (bring-your-own `GEMINI_API_KEY`), so the
app needs **no backend server** for summaries.

It is a client-side port of the old `ogmo-cf/src/summarizeTranscript.ts`, which
already used Gemini (`gemini-2.5-flash-lite`, structured JSON output). **Only the
transport moved into the client** — the response contract (`SummaryAPIResponse`)
is byte-for-byte identical, so everything downstream (`SummaryViewModel`,
`saveStructuredSummary`, the Firestore mirror, the ActionItems/KeyPoints screens)
is untouched.

## Decisions

1. **Direct REST call, no SDK.** A plain `URLSession` request to
   `POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent`.
   No dependency added — the request/response are small and stable, and the app
   already talks to Soniox/Firebase over `URLSession`.

2. **Key in the `x-goog-api-key` header, not `?key=`.** Both are valid; the header
   keeps the key out of any URL logging. The key is read at runtime from
   `Bundle.main.infoDictionary["GEMINI_API_KEY"]` (injected from the git-ignored
   `Config.xcconfig`) — the same pattern as `SONIOX_API_KEY`. No key is hardcoded
   in committed source.

3. **Request shape mirrors the TS `config`.** Transcript (the flat plaintext blob
   from `ConversationFormatter.buildTranscript`, fullwidth-colon speaker separators
   and all) goes in `contents`; the ported prompt goes in `systemInstruction`;
   `generationConfig` sets `responseMimeType: "application/json"` + a
   `responseSchema`. The schema uses uppercase REST types (`OBJECT`/`STRING`/`ARRAY`),
   lists `title`/`shortDescription`/`summary`/`keyPoints` in `required` (so
   `actionItems` stays **optional**, matching `SummaryAPIResponse.actionItems: [String]?`),
   and pins `propertyOrdering` for stable output.

   **Update 2026-07-29 (#14):** both halves of this changed. The transcript is no
   longer a plain speaker-labelled blob — every diarized line now carries its
   numeric speaker id (`Speaker 2 (Alice)：…`) and a speaker roster precedes the
   dialogue, so the response can map a predicted name back to an id. And the schema
   gained a second optional field, `speakers`, alongside `actionItems`; it also moved
   out of `SummaryService+Gemini.swift` into its own `SummaryService+Schema.swift`.
   See `docs/2026-07-29-macos-speaker-auto-naming.md`.

4. **Response is a JSON string inside a JSON envelope.** The structured summary
   arrives as `candidates[0].content.parts[0].text` — itself a JSON string shaped
   by `responseSchema` — which we then decode into `SummaryAPIResponse` with a plain
   `JSONDecoder` (camelCase keys matched verbatim).

   **Update 2026-07-29 (#14):** still a plain `JSONDecoder`, but note that this
   decode is **all-or-nothing** — a type mismatch in any field aborts the whole
   response. That is why the `speakers` field added for speaker auto-naming is
   wrapped in a type whose `init(from:)` cannot throw, rather than declared as a
   plain optional array.

5. **Prompt reworded off the Ogmo persona.** The system prompt was ported verbatim
   in behavior but its persona changed from "note summarization assistant for deaf
   and hard-of-hearing students" to "the summarization assistant for Open Captions".
   Every behavior clause is preserved: write in the requested language; silently
   correct STT/homophone errors from context; never fabricate; flag genuinely
   ambiguous spots as `[unclear: …]`; highlight commitments/dates/times/locations/
   amounts/deadlines; `summary` = 2–5 flowing-prose paragraphs; `title` ≤ 4 words;
   a one-sentence `shortDescription` that must not start with "This".

6. **Language is still threaded, even though it's hardcoded `"English"`.**
   `summarize(session:language:)` takes a `language: String = "English"` default that
   flows all the way into the prompt, so re-enabling multi-language (once
   `LanguageManager` returns) is a one-line change with no plumbing.

7. **Offline gate unchanged — it stays upstream.** Gemini needs the network and there
   is no on-device summarizer, so summaries remain suppressed in Offline Mode. That
   gate lives in `MacSessionDetailView` (auto-summarize + Re-summarize/empty-state
   buttons) and `PostSessionRetranscriber` — `SummaryService` itself never checks the
   offline flag. See the offline-mode note.

## Error mapping

Gemini failures map onto the **existing** `SessionSummaryError` cases (no new cases;
`analyticsType` stable):

- **Missing/empty key, HTTP 401/403 → `.unauthorized`.** A missing key is treated as
  an auth failure (throws before the request is built).
- **HTTP 400 whose error message mentions "API key" → `.unauthorized`.** Non-obvious:
  Gemini returns **400 `INVALID_ARGUMENT`** ("API key not valid…") for a
  malformed/typo'd/placeholder key — **not** 401/403. Because `Config.xcconfig.example`
  ships a *non-empty* placeholder (`YOUR_GEMINI_API_KEY`), the `!isEmpty` guard passes
  and the bad key reaches the API. So the 400 branch inspects the decoded error and
  routes API-key errors to the tailored `.unauthorized` hint ("check that
  `GEMINI_API_KEY` is set correctly in Config.xcconfig") instead of a generic
  "Bad request". Any other 400 stays `.badRequest`.
- **Network/transport failure → `.networkError`** (`URLSession` throw or non-HTTP response).
- **Malformed or safety-blocked output, other non-2xx → `.serverError`.** Empty
  `candidates`, a `promptFeedback.blockReason`, or a non-`STOP` `finishReason` surface a
  specific reason. In particular a **`MAX_TOKENS` truncation** that leaves partial JSON
  (which then fails to decode) reports "stopped early (MAX_TOKENS)" rather than a generic
  "malformed", by falling back to `finishReason` on decode failure.
- **Empty transcript → `.emptyConversation`**, still guarded locally in `summarize`
  before any network call.

## Files

- `OpenCaptions/Services/SummaryService.swift` — slimmed to the core: `SessionSummaryError`,
  the unchanged `SummaryAPIResponse`, `summarize(session:language:)`,
  `saveStructuredSummary`. Removed the old `SUMMARIZE_URL`/`SUMMARIZE_API_TOKEN` readers,
  the old `callSummarizeAPI`, and the now-dead `SummaryAPIError`. (`.unauthorized`
  copy updated to reference `GEMINI_API_KEY`.)
- `OpenCaptions/Services/SummaryService+Gemini.swift` — **new.** The transport:
  key read, request build, status switch + error mapping, response decode, and the
  private Gemini DTOs (`GeminiResponse`, `GeminiErrorResponse`). `callSummarizeAPI` is
  `internal` (not `private`) only because it's called from the core file across the
  extension split.
- `OpenCaptions/Services/SummaryService+Prompt.swift` — **new.** The reworded
  `systemInstruction(language:)`, isolated because it's the piece most likely to be tuned.
- `OpenCaptions-Info.plist` — `GEMINI_API_KEY` → `$(GEMINI_API_KEY)` mapping.
- `Config.xcconfig` / `Config.xcconfig.example` — `GEMINI_API_KEY` added (git-ignored
  real value; documented placeholder in the example).

The three-file split keeps each under the ~250-line house limit (`Type+Feature.swift`
convention). (**Update 2026-07-29:** now four — #14 extracted `responseSchema` into
`SummaryService+Schema.swift` for the same reason.)

## Config note (`SUMMARIZE_API_TOKEN`)

`SUMMARIZE_API_TOKEN` was the shared bearer for both the old summarize endpoint and the
RevenueCat minute-deduction endpoint. Its second consumer went away with the RevenueCat
removal (#4, commit `73cf54d`), so #3 lands **last** and drops the final read here.
Neither `SUMMARIZE_URL` nor `SUMMARIZE_API_TOKEN` was ever present in the committed
`Config.xcconfig(.example)` or `OpenCaptions-Info.plist` — the only references were the
code reads in `SummaryService`, now gone.

## Verification

Build the **OpenCaptions** scheme in Xcode. With a real `GEMINI_API_KEY` filled into
`Config.xcconfig` (get one at https://aistudio.google.com/apikey):

- Open a saved session with a transcript but no summary → auto-summarize on appear
  produces title + short description + 2–5 overview paragraphs + key points + action items.
- "Re-summarize" (toolbar) and the empty-state "Summarize" button regenerate.
- Re-transcribe/import (`PostSessionRetranscriber`) regenerates the summary — skipped
  while Offline Mode is on.
- Offline Mode on → summary generation is suppressed with the "unavailable offline"
  state; an already-generated summary still renders.
- Leave the key empty / paste a bad key → the summary tab shows "Couldn't Summarize"
  with the `GEMINI_API_KEY` hint, no crash.

> Note: a fully clean build is currently blocked by an **unrelated, pre-existing**
> FluidAudio break (`NemotronStreamingAsrManager` ASR API drift in
> `NemotronTranscriberService.swift`). None of the summary files produce errors or
> warnings.

## Out of scope (follow-ups)

- Multi-language summaries (the `language` param is wired; `LanguageManager` is deferred).
- Retry/backoff on 429/5xx (currently surfaced as `.serverError`).
- Token-budget handling for very long transcripts (no `maxOutputTokens` set; relies on
  the model default).
