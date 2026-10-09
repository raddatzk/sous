# AI API integration

Status: draft, 2026-10-08. Nothing implemented. Local models were evaluated in a spike
(Ministral 3 3B: fine on the Mac, too tight on the iPhone for editing tasks) and are
postponed; this concept replaces them with remote APIs.

## Goal

An alternative to the copy-paste flow: Sous sends the prompt to an AI provider itself and
shows the conversation in a sheet. Copy-paste stays as the third option for people without
an account.

## What exists

- `RecipeOptimizationBackend` (`answer(to:) async throws -> String`) in
  `RecipeOptimization.swift` is the transport seam. `CopyPasteBackend` in
  `RecipeOptimizationSheet.swift` is the only conformance.
- Strict readers validate every answer: `RecipeOptimizationPrompt.read`,
  `StepReferencesPrompt.reading`, `RecipeReplacement.read`. An API answer goes through the
  same readers; nothing is written without them.
- `RecipeAIEditSheet` and `StepReferencesSheet` call the pasteboard directly and have no
  backend protocol yet.
- Household prompts: `PromptTemplate` (household only, `CDPromptTemplate`). They are sent
  along with the request exactly as in the copy-paste flow.
- `OptimizationChat` (ChatGPT, Claude, ...) picks the chat for copy-paste; `off` ("Keine KI
  verwenden") hides all AI entry points and stays the overriding opt-out.
- No Keychain use yet; networking only in `RecipeWebImporter` (injectable `URLSession`).

## Providers

`LLMProvider`: kind (`anthropic` | `openAICompatible`), base URL, model, display name.

| Provider | Kind | Notes |
|---|---|---|
| Anthropic | `anthropic` | `POST /v1/messages`, `x-api-key`, `anthropic-version`, top-level `system`, `max_tokens` required, SSE `content_block_delta` |
| OpenAI, Grok, Gemini (compat endpoint) | `openAICompatible` | `POST /v1/chat/completions`, `Authorization: Bearer`, `system` role, SSE `delta` |
| Custom (Ollama, LM Studio, ...) | `openAICompatible` | free base URL; plain-HTTP localhost needs an ATS exception (to check) |

Presets for the four named providers; everything else through the custom entry.

## Keys and precedence

- **Personal key:** Keychain with `kSecAttrSynchronizable` (iCloud Keychain), so it follows
  the user across devices.
- **Household key:** a household row (like `CDPromptTemplate`) holding provider, URL, model
  and key. The key attribute uses `allowsCloudEncryption` (to verify that the model builder
  supports it). Only the creator edits or deletes it. Members can use it, and the sharing UI
  says that it is decrypted on their devices.
- **Resolution:** `off` > personal > household (active household) > copy-paste.
- A failing personal key (limit, expired) never falls back silently, because someone else
  would pay. Sous asks "Use the household key?".
- Every request shows who pays ("via Anthropic (personal)", "via OpenAI (household: Name)").
- Multiple households: the key belongs to the household; the active one counts.

## Chat sheet

- Bottom sheet, `.sousSheetSizing(.page)`, ✕ closes, streamed answer, input field for
  follow-ups.
- A proposal (references, optimization, edit) is shown in the sheet and written to the
  recipe only after "Übernehmen", through the existing strict readers.
- Swipe-to-dismiss is locked only while there are unsaved changes.
- First use shows what is sent (recipe text, notes) and to whom.

## Settings

- Personal: new section next to the chat picker in `SettingsView`.
- Household: new row in `HouseholdPage` next to "KI-Prompts".

## Product shape

- **Optimieren** is a button without a chat: one request, one checked result the cook can
  accept line by line (as today, only the transport changes).
- **Mit KI bearbeiten** opens the chat sheet. Whatever the cook accepts comes out in Sous's
  line form, too:
  1. The model's recipe is read by the replacement reader (shape only).
  2. A local lint, without a model, checks the result's lines: amount, unit, a raw
     ingredient, no preparation words, names known to the catalog. This does not exist yet;
     the optimizer's line analysis has to be pulled out so that it runs on a recipe rather
     than on a model's answer.
  3. Only where the lint finds something, one more request runs the optimizer with the
     *edited* recipe as the baseline. Against the original, the optimizer's checks would
     refuse every legitimate change (mince becomes lentils).
  4. The cook sees the final result once. This runs on "Übernehmen", not on every chat turn.

## Catalog in the prompt

The prompt carries the whole ingredient catalog today (about 12,000 to 20,000 input tokens
per request, most of it the catalog). Two ways down, no hierarchy in the catalog:

- **Optimizing:** the names are in the recipe. Sous resolves them locally and puts only the
  matching catalog entries in the prompt. No tools, no loop.
- **Editing:** new ingredients appear (oat drink for milk). A `suche_zutaten` tool takes
  several terms at once and returns up to five hits per term (partial words, aliases,
  typos). The model brings the hierarchy itself: asked for "plant milk" it searches for
  oat, soy and almond milk. No match: it proposes the most concrete name as new. A name
  that still arrives unknown is flagged by the reader and the cook decides.
- Measure both against the full catalog with the bench before switching.

## Models and the bench

`SousKit/Tests/SousKitTests/AIModelBench.swift` asks real models to do the tasks and scores
them with the app's readers. It only runs with `SOUS_AI_BENCH=list|run|rescore`, reads keys
from `~/.sous-bench-keys`, saves every raw answer. 2026-10-08, five recipes, one run each:

- Small and cheap models are enough: Grok 4.20 (non-reasoning), Gemini 3.5 Flash Lite,
  GPT-5.4 mini, GPT-5.6 Luna, Claude Haiku 4.5, Sonnet 5.5 all passed 3-5 of 5 optimizations
  and 3-4 of 4 edits. One recipe of difference is noise.
- Newer Anthropic models think before answering and the thinking counts against
  `max_tokens`: Haiku 5.5 hit 8192 and cut its JSON off (1/4 on edits). With 16384 it
  passes 4/4, at 25 s and about 6,100 output tokens per request against Haiku 4.5's 8 s and
  1,000. The adapter reports `wasCutOff` so the app can say so.
- Suggested defaults, shown as "recommended" and only if the provider's model list has them:
  Grok `grok-4.20-0309-non-reasoning`, Gemini `gemini-3.5-flash-lite`, OpenAI `gpt-5.4-mini`
  (fast) or `gpt-5.6-luna` (quality), Anthropic `claude-haiku-5-5`. The list lives in
  code so that an app update can change it.
- Cost of one edit at the published prices (2026-10-08, prompt under 100k tokens): Haiku 4.5
  about 2.2 ct (16,400 in, 1,050 out, 1 $ / 5 $ per MTok), Haiku 5.5 about 0.5 ct (21,800 in,
  6,200 out, 0.10 $ / 0.50 $ per MTok). Cheaper per request in spite of the thinking tokens,
  but slower (25 s against 8 s). The token counts the adapter reads match the console's.
- Haiku 5.5 has an adjustable effort (`output_config.effort`, default `medium`) and thinking can
  be turned off up to `high` (`thinking: {"type": "disabled"}`). Same five recipes: default 19-25 s
  and about 5,000-6,000 output tokens; `low` 19 s; `low` without thinking 5 s and about 1,100
  tokens, 5/5 on optimizing and 4/4 on editing (about 0.26 ct per request). The app asks Haiku 5.5
  that way (`LLMModelAdvice.tuned`). Re-run the bench before changing it.
- Models that answer in prose without the JSON block: the reader says `noAnswer`, Sous asks
  once for "the current state as a JSON block". Implemented in the bench, not yet in the app.
- Gemini answers 503 under load: the adapter needs retries with backoff.
- Prompt caching: OpenAI, Grok and Gemini cache a repeated prefix on their own. Anthropic needs
  `cache_control` on the last block of each turn. The prompt builder has to hand over the
  fixed part (rules, catalog) and the variable part (recipe) separately.

## Settings and the chat sheet (2026-10-08)

- One choice "KI" in the settings: Aus, Chat kopieren, Direkt (API). Aus is still
  `OptimizationChat.off` (so the welcome, the step references and the recipe menu keep agreeing);
  `AIMode` stores only copy-and-paste against API (`SousSetting.aiMode`), and `AIMode.effective`
  is what counts. The chat choice shows only in copy-and-paste, the provider only in API.
- API: `RecipeAIChatSheet`, a classic chat (conversation above, field below). A template starts
  the talk at once; "Eigene Änderung …" is the first message. The model explains briefly and does
  not write the recipe out (`RecipeReplacementPrompt.prompt(showsRecipe: false)`); Sous shows a card
  per answer with what is new and what is gone (`RecipeReplacement.changes(from:)`), whole recipe
  a tap away. The latest card, and a button above the field, open the result page (outcome, fields,
  lines in Sous's form, old and new), where the cook confirms.
- A failing provider offers "Mit Kopieren und Einfügen weitermachen", which reopens the request
  in the copy-and-paste sheet. `RecipeAIEditSheet` is copy and paste only again; both sheets share
  `RecipeReplacementDraft` and `RecipeReplacementSections`.
- Checked against Haiku 5.5 with the short prompt: explanations of 280-640 characters, the JSON
  block in every answer; tidying took 4 s and left a line without an amount alone, as it must.

## Mistral (2026-10-09)

Measured with the same five recipes (OpenAI-compatible, `https://api.mistral.ai/v1`):
`ministral-3b-latest` optimizing 1/5, editing 4/4; `ministral-8b-latest` 1/5 and 4/4;
`ministral-14b-latest` 0/5 and 4/4 (unreadable answers: wrong line numbers, steps changed). The
account's plan allowed no requests at all for `mistral-small-latest` and `mistral-medium-latest`
(`x-ratelimit-limit-req-minute: 0`), so those are unmeasured. Not listed in `Community/ki/` for now: no
model passes the optimization, which the app needs. Mistral stays a chat only (`ki/mistral.yaml`).

## Address of a provider moves

A saved connection keeps the address it was made with. If the catalog names another one for the same
provider (found by its catalog id, or for a connection saved before ids by the address it holds being the
catalog's current or a recorded earlier one, never by name), the app shows a notice where the connection
is used and in the settings. The sheet shows both hosts, the provider's announcement and reason from
`moved` where the data has them, the provider's documentation, and asks the cook to check the address
themselves (a switch) before "Neue Adresse übernehmen". Until then the key goes to the old address, and
saving the settings page does not follow the move either. For a household's key, one member's yes changes
the shared row for everyone. The connection notes when the address was confirmed
(`addressConfirmedAt`, also in the household row).

## Steps

1. Adapters + tests (faked `URLSession`), no UI. Done: `AIProvider/`, model list,
   token usage, cut-off detection.
2. Personal key (synced Keychain), settings, API path in the optimization sheet
   (one request, one answer).
3. Chat with streaming and follow-up questions; retry for a missing JSON block; retries for
   busy answers (502/503/504/529, 429 with Retry-After). Done: `RecipeEditChat` in SousKit, and
   `RecipeAIEditSheet` talks to the cook's provider in its own transcript (the sheet is the
   conversation sheet; the proposal below it updates with every answer). Checked against the
   real Anthropic API with the bench (`SOUS_AI_BENCH=chat`).
4. Bearbeiten through the chat sheet, local line lint, optimizer pass on the edited recipe.
   Done: `RecipeTidier` (nothing is asked where `Recipe.isOptimizedForSous` already holds; else
   the optimizer runs over the *edited* recipe and its ticked-by-default lines are taken),
   run by the sheet after each settled answer and shown as "Für Sous"; `applyReplacement(tidied:)`
   saves it. Not for "Als neues Rezept"/"Als Variante", which stay as the model wrote them.
   The lint is the existing `isOptimizedForSous`; no new analysis was needed. Household
   proposals for unknown names are not saved by this pass.
5. Move `StepReferencesSheet` onto the backend protocol.
6. Catalog excerpt for optimizing, caching split, search tool for editing. Done (2026-10-08):
   - Caching: the prompts come in two parts (`RecipeOptimizationPrompt.parts`,
     `RecipeReplacementPrompt.parts`: rules and catalog first, the recipe last); `LLMMessage.cachedPrefix`
     marks the first for Anthropic (`cache_control`), the others cache a repeated start on their own.
     Measured with three recipes in a row: Haiku 5.5 wrote 21,562 tokens to the cache on the first request
     and read them on the next two (input left: 235-319); Gemini 3.5 Flash Lite cached 10,214 of 12,878 from
     the second request on; Grok 4.20 cached 13,184 of 13,353 from the third. OpenAI not measured (no credit).
     A lone request at Anthropic pays 1.25 times for the part it writes, so caching is for the chat, not for
     one-shot optimizing.
   - Excerpt (`excerpt: true`): the catalog rows that the word-by-word search finds for each line, with their
     parents. Input of an optimization falls from 21.8k to 6.4k (Haiku 5.5), 13.4k to 3.9k (Grok), 12.8k to
     3.6k (Gemini). Five recipes, three models: 13/15 with the whole catalog, 13/15 with the excerpt, the
     same number of lines known to the catalog. Used by the optimizing sheet and by tidying; the editing chat
     keeps the whole catalog (new ingredients appear there) and relies on the cache.
   - Search tool for editing: not built. With the cache, a three-turn edit with Haiku 5.5 costs about 0.3 ct
     (0.27 ct to write the prefix, 0.02 ct per read); a tool loop would add round trips and two tool formats
     for little. Worth it only for a model whose input price makes the catalog expensive.
7. Household key. Done (2026-10-09): `CDAIConnection` in the household's rows (provider, address, model,
   effort, key; one row, the newest kept), the key attribute with `allowsCloudEncryption`;
   `CoreDataAIConnectionStore`; "KI-Anbieter des Haushalts" on the household page; `AIConnections` picks
   the cook's own where there is one, else the household's; when the cook's own key is refused or used
   up (401/403/429) the chat and the optimizing sheet offer "Schlüssel des Haushalts verwenden" and say
   who pays; nothing is taken silently. Limits: (a) nobody can be kept from changing or removing the
   household key, because CloudKit shares a zone, not single records: the settings say so; (b) the key
   sits unencrypted in the local Core Data file on each device (the Keychain holds only the personal key);
   (c) not checked: that CloudKit syncs the encrypted field to a member (the simulator's CloudKit does not
   run here), and the production schema has to be deployed before a build writes `CDAIConnection`.

## Open

- ATS exception for plain-HTTP local endpoints.
- Whether follow-up turns re-send the full recipe or only the conversation (the conversation
  carries it; the cache covers the prefix).
