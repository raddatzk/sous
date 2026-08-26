# Ingredients Migration Plan

Companion to [INGREDIENTS-CONCEPT.md](INGREDIENTS-CONCEPT.md) (the target) and
[INGREDIENTS-DIFF.md](INGREDIENTS-DIFF.md) (the gap). This plan turns the diff into
a sequence of shippable phases.

- **Status: shipped** — all six phases have landed on `main`; the eleven concept
  test cases pass as a suite (§6). All reconciliations in §2 are resolved (O1/O2
  decided by the cook on 2026-08-25, following the recommendations).
- Baseline: `main` @ `fa66627`, 2026-08-25.

| Phase | Commit | |
|---|---|---|
| 1 — Honest numbers on today's data | `35078dd` | landed |
| 2 — The shopping list becomes a document | `3ad1bea` | landed |
| 3 — BLS identity | `2cb4ab3` | landed |
| 4 — Vocabulary and the status model | `56dee53` | landed |
| 5 — States and the gram bridge | `177035e` | landed |
| 6 — Update reconciliation | `d8ad583` | landed |

Each phase kept its decisions in the code's doc comments rather than here; this
plan is the road, not the record. Where a phase deliberately departed from the
concept, the departure is named at the place that implements it — and, for the
test cases, in `ConceptScorecardTests`.

---

## 1 · Rules for the whole migration

1. **User data is never lost.** Every schema change carries its data forward;
   checked-off shopping items, own ingredients, aliases, and own nutrition values
   survive every phase. Migrations are tested against a copied store before they
   ship.
2. **Every phase ships a working app.** No long-lived migration branch, no big
   bang. Each phase closes named items of the diff and leaves the rest untouched.
3. **What is beyond the concept stays.** The step-amount machinery
   (`StepAmountResolver`, `AmountAIExtractor`, review sheets), ingredient groups,
   cook mode, editor affordances, and the share extension are not touched except
   where a phase explicitly says so.
4. **The schema stays CloudKit-shaped.** New entities follow the existing pattern:
   no SwiftData relationships, UUID/string value joins, every property defaulted.
   The concept's data-model sketch is mapped onto this shape, not copied literally.
5. **Commits only on explicit request**, as everywhere in this repo.

## 2 · Architecture reconciliations

Where concept and codebase disagree on construction, the migration takes a stance.
Three are decided here (with rationale); two were the cook's call, resolved
2026-08-25.

### Decided

**R1 — Derive-on-read stays; no stored line interpretation.** The concept stores
each line's interpretation so confirmations survive; the codebase re-parses text on
every read. The migration keeps derive-on-read, because every confirmation the
concept cares about lives at the *vocabulary* level (ingredient identity, basis
mapping, aliases, variants, measures) — none of it is per-line. The parser is
deterministic, so derivation is stable; text edits re-resolve exactly as the
concept's re-parse rules demand, for free. Price accepted: per-line overrides
("in this one recipe, 'Tomaten' means something else") are impossible — the concept
never needed them, by design. What must be added instead: the *derived* per-line
status (unrecognized / resolved-with-proposed-basis / resolved-confirmed) computed
against the vocabulary at render time.

**R2 — Vocabulary entities are new, user-space, lazily created.** The concept's
`Zutat` becomes a persisted user-space entity created the first time a name is
used (or touched), absorbing today's three user tables: `StoredCatalogIngredient`
(→ own ingredient, identity confirmed), `StoredIngredientAliasOverride` (→ alias on
the lazily created entity), `StoredCatalogNutrition` (→ own-values basis, status
confirmed). Identity is a UUID; the normalized name + aliases remain the join key
from recipe text. Bundled catalog entries are *not* mirrored eagerly — a vocabulary
row exists only where the cook has state (a confirmation, an override, a variant, a
pantry flag).

**R3 — Nutrient column set stays at today's 16** (Big-8 + the 8 micronutrients),
plus whatever the NRF decision below requires. The concept's "keep the full BLS
column set internally" is deferred: it multiplies bundle size for no current
feature. The pipeline keeps the source xlsx and can widen the set later.

### Decided by the cook (2026-08-25)

**O1 — The NRF score (diff §4.2) → gate on full coverage.** The concept rules out
a health verdict; the app ships an A–E badge — and an A computed from a silently
half-empty sum is doubly misleading. Decision: the badge shows only when nutrition
coverage is complete, implemented in phase 1 where coverage becomes known.
Fallback if gating proves confusing in practice: remove the badge. Rejected:
keeping it unconditionally (a permanent deviation with exactly that misleading
edge).

**O2 — BLS scope (diff §2.2) → keep the group filter, drop the averaging.** The
concept ships all 7,140 rows; the pipeline filters to relevant groups (~2,661
names) and additionally averages colliding variants. Decision: the filter stays —
it is good curation (a full catalog would make the picker offer baby food) — and
only the averaging goes: every surviving BLS row keeps its own code, name, and
values, so the nine Schmelzkäse become nine pickable candidates. The filter list
stays data (`group_codes.json`), so widening the scope later is a data change, not
a code change. This is a documented deviation from the concept's
"ship everything".

## 3 · Bundled data v2 (groundwork for phases 3–6)

One pipeline rework (`Scripts/nutrition/`), producing:

- **`bls.json`** — filtered-per-O2 BLS rows, each with its **SBLS code**, original
  catalog name, food group, and the R3 column set. Raw/cooked remain what they are
  in the source: separate rows. **No averaging.** A `datasetVersion` stamp and the
  license/change-note strings move into the file.
- **`synonyms.json`** — the crown jewel of the current data, recycled: today's
  curated `ingredients.json` names and aliases become the kitchen-word → SBLS-code
  synonym table (weighted where several codes fit). The pipeline's existing
  state-merge logic becomes *mapping* logic: "Kartoffel" → {raw: code A, cooked:
  code B} instead of one averaged row. The 35 curated names without any BLS match
  stay as synonym entries without targets (they resolve identity, not nutrition).
- **`measures.json`** — the gram bridge as data: today's hardcoded generic weights
  (`NutritionResolver.genericImpreciseGrams`) and the 18 piece weights move here;
  **densities** get curated (oils, honey, flour, …); "Tasse" enters the unit
  vocabulary. Every entry is flagged as an assumption for the UI.
- **`aisles.json`** — BLS food group → `IngredientCategory` defaults, so rows that
  have no curated category still land in a sensible aisle.

The xlsx stays out of the repo (as today); the pipeline README documents every
judgment call (as today).

## 4 · Phases

Phases 1 and 2 are independent of each other and of the data rework — they can
swap or run in parallel. Phases 3→6 build on each other.

### Phase 1 — Honest numbers on today's data

*No schema change. Closes diff §3 items: coverage report, invisible
no-nutrition ingredients, "unquantified" category; fixes the cache holes.*

- `NutritionAggregator` returns coverage alongside the sum: per-line contribution
  or gap reason (no catalog match / catalog match but no nutrition / no gram
  equivalent / unquantified). UI shows "≈ 640 kcal pro Portion — 9 von 12
  Zutaten", with the gap list as the drill-down. Subrecipe coverage propagates
  ("aus Naan: 1 Zutat ohne Werte").
- Parser learns the **unquantified** amount kind ("nach Geschmack", "nach
  Belieben", "etwas", "einige") so those phrases stop polluting names and stop
  counting as unknown ingredients; unquantified lines are excluded from coverage
  defects, per the concept.
- Cache correctness: servings enter the cache key (stops the two-view thrash); a
  bundled-dataset fingerprint enters `RecipeContentHash` (stops silent staleness
  across app updates).
- **O1 lands here**: the NRF badge becomes coverage-gated, now that coverage is
  known.

### Phase 2 — The shopping list becomes a document

*Schema migration #1. Closes diff §3: list reconciliation, re-scaling, pantry,
unassigned prominence. Removes contradiction §4.1 (destroyed check-offs).*

- New entities (CloudKit-shaped): **plan entry** (`recipeID`,
  `portionenErfasst` — the scale being viewed at add time — and mutable
  `portionenAktuell`), **demand** (amount as captured, unit, state?, `planEntryID`,
  `lineID`), **item** (ingredient key or raw text, `isChecked`, `late`, `lapsed`).
  Effective amount = captured × aktuell/erfasst.
- Reconciliation rules from the concept: check-off is never reset (re-adding a
  recipe appends demand instead of un-checking); new demand appends as open,
  late-marked rows; lapsed demand is annotated, not deleted. `clearChecked` stops
  deleting rows.
- **Re-scaling in the by-recipe view** (concept §6 "Re-scaling on the list"):
  a portion stepper per plan entry, recomputing from captured demands — never by
  re-reading the recipe, so the snapshot property holds.
- Pantry flag on vocabulary/catalog entries + collapsed "Vorräte" section;
  "Nicht zugeordnet" moves from the bottom (`Sonstiges`) to the top.
- **Data migration:** existing `StoredShoppingEntry` rows carry over with their
  checked state; their title-keyed sources become frozen demands without a plan
  entry (visible, checkable, not re-scalable). Re-scaling works for everything
  added after this phase.

### Phase 3 — BLS identity

*Swaps the bundled data for v2 (§3 above). Closes diff §2.2 keys/versioning;
removes contradiction §4.3 (averaged variants). Mostly invisible to the cook,
except provenance appears.*

- Matching becomes: written name → vocabulary/aliases → synonym table → SBLS code
  → nutrition row. The candidate list (several codes per kitchen word) is carried
  in the result but not yet surfaced — phase 4 builds the picker on it.
- Provenance becomes showable: "beruht auf: <BLS catalog name> (BLS 4.0)" wherever
  a number is explained, starting with the ingredient form and the phase-1
  coverage drill-down.
- **Data migration:** existing name-keyed user data (own nutrition, alias
  overrides) is re-keyed once: name key → SBLS code where the old curated name
  maps cleanly; unmappable rows keep working by name (compatibility path) and are
  flagged for phase 4's review UI. Recipe nutrition caches are dropped wholesale
  (they are caches).

### Phase 4 — Vocabulary and the status model

*Schema migration #2 (R2). Closes diff §3: status model, candidate picker,
"bewusst ohne", per-number provenance, decision-A marking; upgrades variants from
lossy aliases.*

- Vocabulary entity lands; the three legacy user tables fold into it (R2).
- Basis mappings get status **proposed / confirmed / deliberately-without /
  orphaned**; synonym-table hits start as *proposed*. Sums compute with proposed
  bases, visually provisional, with "davon N unbestätigt" in the coverage line
  (concept decision A); batch confirmation view ("5 Zutaten zu klären"), candidate
  picker listing the real BLS rows (the nine Schmelzkäse), custom values, and
  "bewusst ohne" as a confirmed opt-out.
- **Variant relation** (one level, UUID-joined): shopping list groups variants as
  sub-lines under the parent — the lossy one-line becomes the concept's grouped
  entry. Bundled alias lists stay aliases (spellings); variant *proposals* happen
  at new-ingredient creation with the word-ending heuristic (concept decision B).
  Existing bundled aliases that are really varieties (Cocktailtomaten …) are
  re-classified in the curated data, not guessed at runtime.

### Phase 5 — States and the gram bridge

*Closes diff §2.4 and §2.5. The potato and oil cases start computing correctly.*

- Parser reads the closed state vocabulary (roh, gegart/gekocht/…, TK, Konserve,
  getrocknet) from lines; nutrition resolves per state against the per-state code
  mapping, falling back per the concept (default state = as purchased). The
  shopping list annotates states instead of ignoring them.
- `measures.json` goes live: densities end the water-density era for oil; every
  derived gram amount renders with ≈ and is tappable; per-ingredient overrides
  extend beyond the single `Stk.` weight (any unit), stored on the vocabulary
  entity.

### Phase 6 — Update reconciliation

*Closes diff §3 last item. Deliberately last: it presupposes the edges of
everything before it (concept §13).*

- Confirmed mappings store the catalog name and dataset version at confirmation
  time. On first launch after a bundled-data change: silent adoption of changed
  values (concept decision D), an **orphan pass** for vanished codes (mapping →
  orphaned, old name shown, successor proposed via synonym table), and the sources
  screen shows the dataset version trace.

## 5 · Deliberately out of scope

Unchanged from the concept's §11 (purchase units, cooking yield, instruction-text
amounts, diary, external product data, non-portion subrecipe references,
multilinguality) — plus, for the migration specifically: no CloudKit/household
activation (the schema stays ready, per rule 4), no visual redesign beyond what the
phases name, no parser rewrite.

## 6 · Verification

- Each phase extends `SousKitTests` with concept-derived cases; the eleven test
  cases from the concept became a permanent scorecard suite — `ConceptScorecardTests`,
  **11 of 11 passing** against the shipped data, up from 4 pass / 3 partial / 4 fail
  at the baseline (diff §6). Every case is also covered by the suite that owns its
  mechanism; the scorecard exists so that the eleven are named *as* the eleven and a
  case cannot fall out of a later refactor unnoticed.
- Two cases pass by a different route than §9 sketched, and the suite says so where
  it asserts them: the oil case computes 2 EL ≈ 27.6 g from a curated density rather
  than ≈ 20 g from a per-unit gram table (phase 5 — a gram table cannot answer `ml`
  or `l` at all), and the Cocktailtomaten relation ships curated in `synonyms.json`
  rather than being proposed and confirmed, which is a stronger outcome than the case
  asked for. The proposal mechanism it describes is exercised by the Ochsenherztomaten
  case, where the name genuinely is new.
- Store migrations get round-trip tests on fixture stores (checked lists, own
  values, alias overrides).
- The sparring bench (`SOUS_SPARRING=1`) stays as is; pipeline v2 gets a
  golden-file test comparing a handful of known rows (Kartoffel raw/cooked,
  Schmelzkäse count) against the shipped JSON.
