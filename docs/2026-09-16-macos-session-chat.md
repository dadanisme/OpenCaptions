# macOS: Chat with a session

Ports the session-detail **Chat** tab from the pre-extraction multi-platform app
(`OgmoMac`, issues #394/#416/#438/#464/#484) into standalone Open Captions: a
multi-turn Q&A conversation grounded on one saved session's transcript, persisted
per session, answered by either cloud OpenRouter or on-device Apple Foundation
Models.

## What came across unchanged

- **`ChatMessage`** — a SwiftData child of `TranscriptionSession`
  (`chatMessages`, `.cascade`), one row per turn, ordered by `sortOrder`. The
  conversation survives closing/reopening the session and app relaunches.
- **`SessionChatViewModel`** — `load`/`send`/`clear`, keeping the in-memory
  `messages` array and the store in sync. The user's question is persisted
  *before* the request goes out, so a failed answer leaves it in the thread to
  retry from rather than discarding what was typed.
- **The Chat tab UI** (`MacSessionDetailView+Chat.swift`) — bubble list,
  typing indicator, error banner, bottom input bar, and the
  `MarkdownMessageView`/`MarkdownBlockParser` pair that renders block-level
  Markdown in assistant replies (`LocalizedStringKey` alone resolves only
  *inline* styling, so headings/lists/fenced code would otherwise show as raw
  syntax).
- **The system prompt**, ported verbatim from `ogmo-cf`'s `buildSystemPrompt`
  (`src/sessionChat.ts`) — the same provenance `SummaryService+Prompt.swift`
  carries — with "Ogmo" swapped for "Open Captions". Its second paragraph is a
  prompt-injection guard, not politeness: the transcript is arbitrary recorded
  speech and the questions are free text, so either can contain something shaped
  like an instruction.

## What had to change: no backend, no PCC, no kill switch

`OgmoMac`'s Chat had three transports — the `ogmo-cf` `sessionChat` Cloud
Function, on-device Foundation Models, and Private Cloud Compute (macOS 27+) —
selected by a 3-way `ChatProviderKind`, and the whole tab sat behind a remote
`FeatureFlag.sessionChat` kill switch.

None of that survives the port, and each drop follows an existing decision in
this repo rather than being a new one:

- **Cloud transport is OpenRouter direct.** There is no backend to proxy
  through, so `SessionChatService+OpenRouter.swift` POSTs to
  `https://openrouter.ai/api/v1/chat/completions` with the bring-your-own
  `OPENROUTER_API_KEY` — the same endpoint, same key lookup (runtime Keychain
  value first, `Config.xcconfig` second), same attribution headers, and the same
  401/402/400/403 mapping `SummaryService+OpenRouter.swift` already uses. It
  reads the same `LiveSessionStore.openRouterModelKind` too: one OpenRouter
  model choice covers both AI features, which is the call `ogmo-cf` also made
  server-side (one `config/ai` doc for `summarizeTranscript` and `sessionChat`
  alike) rather than a second near-identical picker.
- **No Private Cloud Compute.** This app has no PCC transport for summaries
  either, and no `com.apple.developer.private-cloud-compute` entitlement. Adding
  one for Chat alone would be a new capability, not a port.
- **No kill switch.** `FeatureFlag`/`FeatureFlagService` were removed from this
  repo in 2026-07-27; every feature is compiled in and always enabled. The tab is
  therefore unconditional, and `ask` has no flag guard.

So `ChatProviderKind` is a two-case enum — `.openRouter` / `.foundationModels` —
mirroring `SummaryProviderKind` case for case, gate for gate.

### Why a separate picker rather than reusing Summary Model

Chat gets its own Settings → AI Models → **Chat Model** picker
(`LiveSessionStore.chatProviderKind`, `opencaptions.chatProvider.kind`, default
`openRouter`) rather than following the Summary Model.

It isn't symmetry for its own sake: the on-device context window behaves
completely differently for the two features. A summary is one shot — instructions
plus transcript plus output. A chat turn resends the instructions, **the whole
transcript, and every turn so far**, every time (see below), so it exhausts the
4096-token window far sooner, and a session that summarizes on-device perfectly
well may not survive a single question. Tying the two together would force a user
into on-device Chat they can't use, or cloud summaries they didn't want. This is
the same reasoning that already separates Summary Model from Transcription
Engine.

The "OpenRouter Model" row is now shown when **either** picker is set to
`.openRouter`, not just the Summary Model — otherwise a user who summarizes
on-device but chats in the cloud would have no way to pick the model answering
them.

## Three cross-cutting decisions worth keeping

### The on-device transport rebuilds the `Transcript` every call

Apple's multi-turn guidance is to keep one `LanguageModelSession` alive across
turns, reusing its KV cache. That means holding `@available(macOS 26, *)`-only
state on `SessionChatService`, a class that isn't itself gated — type-erased
storage plus invalidation for every way "same conversation" can break (provider
switched mid-thread, a different session opened, the chat cleared, app relaunch).

Instead `callFoundationModelsAPI` rebuilds a `FoundationModels.Transcript` from
the persisted `[ChatMessage]` history on **every** call.
`ask(session:messages:)` already receives the complete history including the new
question on every call (the cloud transport always worked that way), so this
needed no plumbing at all, and every invalidation case falls out of "always
rebuild". The trade is no KV-cache reuse on a second-or-later turn — a latency
and context cost, accepted for the robustness. Revisit if real numbers justify
the bookkeeping.

Two initializer gotchas found by building in the original port, kept as comments
in the file: `Transcript.Instructions(segments:toolDefinitions:)` has no default
for `toolDefinitions` (pass `[]`), and `Transcript.Response(segments:)` alone
resolves to the macOS-27-only `init(id:metadata:segments:)` overload — pass
`assetIDs: []` explicitly to select the macOS 26 one.

### `AppleIntelligenceContextWindow` extracted

The macOS-26-vs-27 context-overflow error branching (`LanguageModelError` vs the
deprecated `LanguageModelSession.GenerationError`, plus the token-count detail
built from either) lived as two private methods inside
`SummaryService+FoundationModels.swift`. Chat's on-device transport needs it
identically, so it moved to `Services/AppleIntelligenceContextWindow.swift` and
both call in. Behavior is unchanged; only its home is.

### No retry loop

`SummaryService+OpenRouter` retries `408/429/502/503` twice with a 1 s → 4 s
backoff, because a summary is a background/one-shot generation and a silent retry
beats an error. A chat answer is interactive with the user watching a typing
indicator, so Chat throws immediately and the user resends — the same call the
original port made. The cloud transport also sends no `response_format` (a chat
answer is free-form prose) and therefore no `provider.require_parameters`, since
there is no parameter an upstream could silently ignore.

## Storage: schema V2 is now frozen

`ChatMessage` is a new entity and `TranscriptionSession.chatMessages` a new
to-many relationship, so the store needs `OpenCaptionsSchemaV3` and a
`.lightweight` V2→V3 stage (nothing renamed, retyped, or made required).

That surfaced a trap in `OpenCaptionsSchemaV2.swift`, which — unlike V1 — pointed
at the *real, current* `@Model` types instead of freezing copies. Adding
`chatMessages` to the live `TranscriptionSession` would have silently changed
what "V2" means, leaving a real on-disk V2 store matching **no** declared version
and failing the migration outright (a `fatalError` at launch). V2 is therefore
frozen now, the same way V1 is: nested snapshot copies of `TranscriptionSession`
and `Workspace`, with `TranscriptionLine`/`ActionItem` still referenced by their
real types since V2→V3 doesn't touch them. **V3 is the unfrozen one; the next
schema change freezes it and adds a V4.**

## Deliberately not done

- **Streaming.** `ask()` returns one full answer per call, matching the
  original's UX contract. Token-by-token streaming into the bubble list is a
  separate UI change.
- **Tool calling.**
- **Chat in the markdown export.** `Services/Export/` mirrors the session itself;
  a Q&A thread about it isn't part of that record, so `transcript.md` /
  `summary.md` are unchanged and there's no `chat.md`.
- **Clearing the chat on re-transcription.** Re-transcription clears the summary
  (it no longer describes the new transcript), but the conversation is left
  alone — an answer that quotes the old transcript is stale, yet deleting the
  user's own questions without asking is worse. "Clear Chat" is one click away in
  the session's ⋯ menu.
- **Live verification of the on-device path.** The OpenRouter path is ordinary
  HTTP; exercising a real Apple Intelligence generation needs Apple Intelligence
  enabled on an eligible Mac — same caveat the Foundation Models summary note
  carries.
