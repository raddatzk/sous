# Sous — Vision

## In one sentence

A personal recipe management and meal planning app for iOS/macOS in the spirit of Mela — but with local AI integration for recipe generation, leftover cooking, web research, and automated, nutrient-optimized weekly meal planning.

## Starting point

Mela is currently in use and is broadly satisfactory, but appears to no longer be actively developed. Rather than a 1:1 rebuild, this is a distinct app — not a feature clone (RSS feeds, for example, are deliberately left out) — with meaningful AI value on top, which Mela lacks.

## Guiding principle for the AI architecture

**The right tool for the right job.** AI handles language, structuring, extraction from unstructured sources (web, video), and creative generation. Conventional code and external databases handle arithmetic, nutritional facts, and optimization.

Rationale: language models are unreliable with numbers and facts (plausible-sounding but wrong nutrition values), yet very strong at narrowly scoped structuring tasks — especially with Apple's `@Generable` mechanism, which yields guaranteed-valid, parsed output instead of free-form text. This separation runs through the entire architecture.

## Core features

1. **Recipe management** — list, categories, favorites, "want to cook", a long-press that previews the recipe itself with its actions underneath rather than a bare menu, cook mode, serving scaling, recipes linked from one another (a curry references the naan, which is an ordinary recipe in its own right), and a plan that is either dated or loose — meals sit on a day or in an undated pool, and move between the two — which the optimizer later builds on
2. **AI recipe generation from the personal collection** — new recipes in the user's own style, via retrieval (tool calling against the local database) plus structured generation
3. **Ad-hoc leftover cooking** — free-text input ("zucchini and feta need to go"), no persistent pantry record, reusing the same generation mechanism as feature 2
4. **Web research for new recipe ideas** — scraping of comparable existing recipes as a tool, using the same structured extraction path as the conventional URL import
5. **Video import (Instagram/TikTok/YouTube)** — implemented as a **share extension**: the user shares a post into the app, and the app processes what it is handed rather than fetching from the platform itself (see Distribution below). Where a video file is available, actual video analysis applies: keyframes through Vision framework OCR (on-screen text), audio track transcribed through the Speech framework, fed into the same extractor together with the caption. Not "video understanding" by a single model — this is decomposition into text, not true video comprehension, but it covers the cases where the caption does not carry everything.
6. **Per-recipe nutrition** — ingredients extracted and normalized structurally (AI), matched against an external nutrition database (conventional code)
7. **Shopping list** — assembled from a stretch of planned days or from the undated pool, with amounts of the same ingredient added together
8. **Automatic, nutrient-optimized weekly plan** — deterministic algorithm against a nutrient/calorie target vector, drawing first on what is already in the undated pool and then on the recipes the user has marked "want to cook"; AI is used only to generate new recipes when the existing recipe pool cannot close a gap
9. **Household sharing** — a household is the unit of sharing: one owner invites members, and the household's recipes and meal plans are shared with all of them. Individual profiles (diet, exercise load, etc.) stay personal and feed into personal nutrition targets.

## Technical architecture pillars

* **Foundation Models framework** (on-device, `@Generable`, tool calling) as the baseline on both iPhone and Mac — free, offline, private
* **MLX as a swappable, stronger backend on the Mac** for tasks where the 3B system model is too bland (primarily creative recipe generation). Since WWDC 2026 the framework sits behind a `LanguageModel` protocol with interchangeable backends — the on-device system model, Private Cloud Compute, Core AI for custom weights, and `MLXLanguageModel` for Hugging Face MLX models — so the backend can be swapped per feature without touching the feature code.
  * **To verify before relying on this:** whether guided generation (`@Generable`) and tool calling behave with the same guarantees on arbitrary MLX models as they do on the system model. Constrained decoding is model-dependent. This warrants a one-day spike.
* **Context budget is a hard design constraint.** The on-device system model has a fixed 4096-token context window per session, and instructions, tool definitions, the `@Generable` schema, and the running transcript all count against it. A full recipe costs roughly 500–1000 tokens, so only two or three retrieval hits fit. Retrieval must therefore return condensed recipe profiles (style markers, ingredient signature) rather than full text, with pre-selection done in conventional code. `contextSize` and `tokenCount(for:)` (iOS 26.4+) are used to budget this explicitly rather than guessing.
* **Mac and iPhone run independently.** Where the iPhone is too weak for a task, that is accepted, or offloaded to a self-hosted Ollama server or a paid cloud API (Claude/ChatGPT — billed separately from the chat subscription, pay-per-token). Recipe generation grounded in the personal collection is expected to be one of those Mac-first features.
* **Local-first persistence with SwiftData.** The device holds the authoritative working copy. Search, filtering, serving scaling, nutrition calculation against the locally cached BLS data, and retrieval for the AI features all run against the local store — they have to, both for offline use and because the AI features need local data anyway.
* **Supabase as an encrypted sync layer, not as a query backend.** Android is a plausible future target, which rules out CloudKit; and the operator (i.e. the developer) must not be able to read user data, which rules out any backend that queries the data server-side. These two together mean the server is a transport and access-control layer only:
  * **Plaintext in Postgres:** household membership, blob IDs and their household, timestamps, tombstones, and per-member wrapped keys. Row Level Security governs which rows a client may fetch at all.
  * **Ciphertext:** recipes, meal plans, and profiles, encrypted client-side.
  * **Images are their own blobs**, referenced by the recipe rather than embedded in it (where Mela's format puts them as base64). They are large and rarely change, so inlining them would mean re-encrypting and re-uploading every photo whenever a word of the text changes. They are downsized on import — a stored image is at most 2048px on its long edge, with a 400px thumbnail beside it for lists.
  * **Key model:** one symmetric AES-256-GCM key per household, wrapped for each member with their X25519 public key; private keys live in the Keychain / Android Keystore, backed by a recovery passphrase. No forward secrecy and no asynchronous delivery to strangers are needed, which keeps the scheme small.
  * **The crypto is implemented in-house**, behind a narrow protocol (`encrypt`, `decrypt`, `wrapKeyFor`, `rotate`) so a managed SDK could still replace it later. This is the well-trodden path, not the exotic one: Bitwarden, 1Password, Ente, Proton, Standard Notes, and Anytype all implement this same pattern and none of them uses an E2EE SDK. Bitwarden calls it the Organization Symmetric Key, Ente calls it the Collection Key; here it is the household key. The Bitwarden security whitepaper serves as the specification and Ente's open-source code as the reference implementation. The managed alternatives (Seald, Tanker, Virgil E3Kit, IronCore) were evaluated and rejected: pricing is not public, the market has consolidated into acquisitions by companies serving their own needs (Seald → OVHcloud, Tanker → Doctolib), and switching provider later means re-keying every user at once.
  * **Note on what this rules out:** no server-side filtering, sorting, joins, or full-text search over recipe content, and metadata (who is in which household, how many recipes, when they changed) remains visible to the operator. Encrypting metadata as well is a different order of magnitude and out of scope.
* **User management: authentication and decryption are deliberately separate.** Supabase Auth answers who may log in; it cannot answer who may read, because any secret it verifies is a secret the server has seen.
  * **Login** through Supabase Auth (Sign in with Apple on iOS, Google on Android).
  * **Decryption** through a separate passphrase the server never receives. Argon2id derives a key from it, which encrypts the user's X25519 private key; the wrapped private key may then be stored server-side, since it is worthless without the passphrase. A new device logs in, fetches the wrapped key, and unwraps it locally — no device-to-device pairing needed, which removes most of the multi-device complexity.
  * Two secrets instead of one is the honest cost, and the passphrase is unrecoverable: issuing a recovery code at signup is mandatory, not optional.
  * **Inviting a member requires an existing member to come online**, because the household key can only be wrapped once the invitee's public key exists — the server cannot do it. An invitation therefore has a pending state. Putting the secret in the invitation link instead avoids this but exposes it to whichever messenger carries the link.
  * **The planning-relevant part of a profile must live under the household key**, not privately: the weekly plan optimizer computes shared meals across all participating profiles, so the device doing the computation must be able to read the others' diets, allergies, and target vectors. Private profiles and shared planning are mutually exclusive. Profiles therefore split into a household-visible part (diet, allergies, nutrient targets) and a private remainder.
* **Requirements this places on the phase-1 data model** — cheap now, a migration later:
  * A recipe is a self-contained aggregate (recipe + ingredients + steps) that serializes as one unit
  * Stable UUIDs rather than autoincrement IDs, so records created offline sync without collisions
  * `updatedAt` and a tombstone flag from the start, because deletions cannot be retrofitted into a sync protocol
  * `createdBy`, and later a household reference, on every recipe
* **Distribution: App Store.** This rules out fetching media from Instagram/TikTok directly — under App Store Review Guideline 5.2.3, apps that download third-party media without platform authorization are rejected, including when official APIs are used. Hence the share-extension design for video import. Importing a recipe from a URL the user supplies is unaffected and remains standard practice.
* **Nutrition data:** Bundeslebensmittelschlüssel (BLS) 4.0 as the primary source — license-free since 2025-12-16 under CC BY 4.0 (attribution to Max Rubner-Institut required in-app), ~7,140 foods, 138 nutrients, German-language. It is a curated staple-ingredient catalog rather than a barcode catalog, which is exactly what recipes need, and it largely removes the German→English ingredient normalization problem. USDA FoodData Central (CC0) and Open Food Facts serve as supplements for branded and packaged products.
* **Weekly plan optimizer:** greedy construction followed by local swap improvement, scored by a cost function with asymmetric penalties (see below), plus variety and cooking-effort constraints.

## Weekly plan optimizer — scoring

The nutrient target vector has mixed constraint directions and must not be treated as a pure deficit-coverage problem:

* **Lower bounds** (protein, fiber, micronutrients) — under-delivery is penalized
* **Upper bounds** (calories, saturated fat, sugar, sodium) — over-delivery is penalized
* **The undated pool is what the optimizer plans with.** Meals in the pool are already decided on — chosen, with a serving count, just not scheduled — which makes them a stronger signal than a "want to cook" mark and the natural material for filling a week. The optimizer therefore seats the pool first, falls back to marked recipes, and only then reaches into the wider collection. **Dated entries are not its to move**: a meal on a Thursday is there because somebody put it there, and rearranging it would make the plan something the cook has to check rather than trust. The optimizer fills what is empty.
* **"Want to cook" is a wish the plan honours** — a recipe the user has marked is one they already decided they feel like eating, which is the one thing a nutrient target vector cannot know. It enters the cost function as a bonus on top of the nutrient score, not as a constraint: the optimizer reaches for marked recipes ahead of the rest of the collection and passes one over only when it cannot be fitted without breaking the bounds. A bonus rather than a hard requirement, because a plan that seats every marked recipe at the cost of the nutrient targets has stopped being an optimizer and become a queue. **Cooking consumes the mark**: it clears itself once the recipe has actually been cooked, not when it is planned — a plan can be rearranged, and a wish the cook never got round to should stay on the list. Otherwise every mark would have to be cleared by hand, and a list nobody prunes stops meaning anything.

A plain greedy "cover the largest remaining deficit" pass systematically overshoots the upper bounds and cannot take anything back, and its final day is left closing whatever gap remains with whatever is available. With 7 days × n recipes the search space is small, so greedy construction plus a local swap pass (exchange a single meal whenever it lowers total cost) is cheap and produces markedly better plans.

## Handling special cases (multiple users/profiles)

* **Dietary and allergy constraints combine as a union of the prohibition lists** — an item is off-limits if it is off-limits for *any* participating profile. This single rule covers both nested diets (vegan ⊂ vegetarian falls out correctly on its own) and orthogonal constraints (diet + allergy), so no special-casing is needed.
* **Shared nutrition targets for a shared meal:** minimize the largest remaining shortfall across all participating profiles, rather than attempting to hit every profile exactly at once.

## Deliberately out of scope

* RSS feeds (Mela's differentiator, but explicitly not wanted)
* Persistent pantry/inventory management — leftover cooking runs purely on ad-hoc input, with no expiry-date tracking. Consequently, the weekly plan optimizer has no expiry data to weight against; ingredient-expiry weighting is out of scope with it.
* Camera-based automatic fridge/pantry recognition
* Factoring existing fixed eating habits (shake, cereal, kebab) into the weekly plan calculation — at least in the first version
* LoRA adapter training for personalization. Evaluated and dropped: an adapter is bound to one specific base-model version and must be retrained on every OS model update, Apple advises against it for most apps on size grounds, and it applies only to the system model — which conflicts with the swappable-backend approach. Few-shot prompting with the user's own recipes, combined with a stronger MLX model on the Mac, targets the same goal at a fraction of the cost.

## Open questions

Not fundamentally unresolved, but not yet settled in detail. Each should be decided before the phase it affects.

**Blocking phase 1:** none — the recipe data model is settled (see below).

**Recipe data model — text is the truth, structure is derived.** Ingredients and instructions are stored as written text, one entry per line, matching Mela's file format field for field. The structure needed for scaling, nutrition and shopping lists is parsed from that text on demand rather than stored in its place. The reason is that no parser understands every line: "3-4 Tomaten" scales from its lower bound, but the line itself must survive editing untouched. Storing the parse result would quietly rewrite what the user typed. Two consequences worth noting:

* Importing a Mela library becomes a direct copy rather than a conversion.
* Phase 2 cannot attach nutrition data to an ingredient by storing it on the line. It needs its own table keyed by recipe and line content, so that re-parsing does not orphan the match. Parsing is deterministic — identifiers are derived from content and position — which is what makes such a key possible.

**Later:**

* Household lifecycle: key rotation when a member leaves (data they already hold stays readable with the old key), and whether a member can take a copy of a recipe with them
* Whether to hand-roll the crypto or adopt a managed E2EE SDK — pricing for Seald and the maintenance status of Virgil E3Kit both need checking before that can be decided
* Whether the weekly plan optimizer draws only on the household's own recipes or also pulls in automatically researched ones, and which meals it covers
* Whether the "want to cook" bonus should decay for marks the user has been carrying for months, or count the same on day one and day two hundred
* Whether the optimizer may put a meal back into the pool when it cannot place it — a plan that quietly drops something is worse than one that hands it back undated
* Whether a single user can belong to more than one household (e.g. shared flat plus family)

## Rough phase roadmap

1. **Recipe management + AI generation from the user's own recipes** (including ad-hoc leftover cooking) — see the separate implementation prompt for Claude Code
2. **Nutrition database binding** (BLS)
3. **Automatic weekly plan optimizer**
4. **Web research & video import**
5. **Sharing / multi-user profiles & conflict resolution**

Nutrition is pulled ahead of web research and video import: it shapes the ingredient data model and blocks the optimizer, whereas video import is the most expensive feature with the lowest return and the highest legal risk.

## Target devices

The Mac (M4 Pro, 48 GB unified memory) is over-qualified for every AI backend tier, including custom MLX models beyond Apple's system model. On iPhone, the available on-device model tier depends on the specific device (base model from iPhone 15 Pro onward; the stronger model only with 12 GB RAM — iPhone Air / 17 Pro / Pro Max).
