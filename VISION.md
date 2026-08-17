# Sous — Vision

## In one sentence

A personal recipe management and meal planning app for iOS/macOS in the spirit of Mela — but with local AI integration for recipe generation, leftover cooking, web research, and automated, nutrient-optimized weekly meal planning.

## Starting point

Mela is currently in use and is broadly satisfactory, but appears to no longer be actively developed. Rather than a 1:1 rebuild, this is a distinct app — not a feature clone (RSS feeds, for example, are deliberately left out) — with meaningful AI value on top, which Mela lacks.

## Guiding principle for the AI architecture

**The right tool for the right job.** AI handles language, structuring, extraction from unstructured sources (web, video), and creative generation. Conventional code and external databases handle arithmetic, nutritional facts, and optimization.

Rationale: language models are unreliable with numbers and facts (plausible-sounding but wrong nutrition values), yet very strong at narrowly scoped structuring tasks — especially with Apple's `@Generable` mechanism, which yields guaranteed-valid, parsed output instead of free-form text. This separation runs through the entire architecture.

## Core features

1. **Recipe management** — list, categories, favorites, "want to cook", cook mode, serving scaling, cross-linking between one's own recipes
2. **AI recipe generation from the personal collection** — new recipes in the user's own style, via retrieval (tool calling against the local database) plus structured generation
3. **Ad-hoc leftover cooking** — free-text input ("zucchini and feta need to go"), no persistent pantry record, reusing the same generation mechanism as feature 2
4. **Web research for new recipe ideas** — scraping of comparable existing recipes as a tool, using the same structured extraction path as the conventional URL import
5. **Video import (Instagram/TikTok/YouTube)** — implemented as a **share extension**: the user shares a post into the app, and the app processes what it is handed rather than fetching from the platform itself (see Distribution below). Where a video file is available, actual video analysis applies: keyframes through Vision framework OCR (on-screen text), audio track transcribed through the Speech framework, fed into the same extractor together with the caption. Not "video understanding" by a single model — this is decomposition into text, not true video comprehension, but it covers the cases where the caption does not carry everything.
6. **Per-recipe nutrition** — ingredients extracted and normalized structurally (AI), matched against an external nutrition database (conventional code)
7. **Automatic, nutrient-optimized weekly plan** — deterministic algorithm against a nutrient/calorie target vector; AI is used only to generate new recipes when the existing recipe pool cannot close a gap
8. **Household sharing** — a household is the unit of sharing: one owner invites members, and the household's recipes and meal plans are shared with all of them. Individual profiles (diet, exercise load, etc.) stay personal and feed into personal nutrition targets.

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

**Blocking phase 1:**

* **The recipe data model in detail** — serving scaling, recipe cross-linking, unit handling. The ingredient line is where nutrition later succeeds or fails, not the database binding: quantity, unit, optional normalized gram amount, ingredient name, and preparation note ("finely chopped") belong in separate fields from day one, along with a raw/cooked distinction. "1 onion", "a pinch", and "100 g pasta (raw vs. cooked)" are the hard cases. Retrofitting this is a data migration.

**Later:**

* Household lifecycle: key rotation when a member leaves (data they already hold stays readable with the old key), and whether a member can take a copy of a recipe with them
* Whether to hand-roll the crypto or adopt a managed E2EE SDK — pricing for Seald and the maintenance status of Virgil E3Kit both need checking before that can be decided
* Whether the weekly plan optimizer draws only on the household's own recipes or also pulls in automatically researched ones, and which meals it covers
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
