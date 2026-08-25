# Ingredients Concept — Implementation Diff

Companion to [INGREDIENTS-CONCEPT.md](INGREDIENTS-CONCEPT.md). Records where the
implementation stands relative to the concept — findings only, no migration plan
(that comes later, as its own step).

- **Snapshot:** `main` @ `0ba610a`, surveyed 2026-08-25. The concept was written
  blind to this code; this diff is the first contact between the two.
- **Verdict in one line:** the *philosophy* matches to a surprising degree (text as
  untouchable truth, deterministic parsing, two data worlds, snapshot shopping list,
  subrecipe resolution). The big gaps are the *honesty layer* (status model,
  coverage report, per-number provenance), and the one deep architectural divergence
  is *how* the kitchen-language problem is solved: pre-translated by a pipeline
  instead of mapped at runtime — at the cost of BLS identity.

---

## 1 · Already matching

- **Text is sacred.** `StoredRecipe` stores only `ingredientsText` /
  `instructionsText`; parsing is a read-time layer
  (`SousKit/Sources/SousKit/Parsing/IngredientParser.swift`); scaling never rewrites
  stored text (`Scaling/RecipeScaling.swift`). Concept principle I, verbatim.
- **Deterministic ingredient-line parser, no AI** — numbers, Unicode fractions,
  ranges, units, parentheticals, group headings.
- **Two data worlds with value references.** Bundled JSON (read-only, replaced on
  update) vs SwiftData user data, joined exclusively by key strings — zero SwiftData
  relationships in the entire schema. `StoredIngredientAliasOverride` is even
  explicitly designed as an update-surviving delta.
- **Custom ingredients, aliases, and nutrition values** exist, shadow bundled
  entries, survive updates; bundled values are deliberately read-only.
- **Shopping list as snapshot, not live view** — `ShoppingListStore.swift:5-7`
  carries the same rationale as the concept ("a list that rewrites itself while
  shopping is worse than useless"). Unit-wise summing without forced conversion;
  spoons are never turned into grams for shopping (`IngredientUnit.shoppingGroup`).
- **Subrecipes**: markdown link (`[Naan](sous://recipe/<uuid>)`), recursive
  flattening for shopping *and* nutrition, cycle detection via visited-set + depth
  cap 3, portion-unit rule — near 1:1 with the concept.
- **Unquantified lines don't scale**; fraction glyph rendering for piece counts.
- **Attribution**: Settings has the BLS 4.0 source, the change note, and the
  CC BY 4.0 link (`Sous/Views/SettingsView.swift:30-47`); per-entry "Quelle:" in
  the ingredient form.
- Concept test cases that already pass: **Ajvar** (alias once, applies everywhere),
  **veganes Hackfleisch** (own entry + own values, shopping unaffected), **values
  added later across twenty recipes** (catalog mutations call
  `nutritionCache.invalidateAll()`).

## 2 · Same intent, different construction

1. **Identity without stored interpretation.** Concept: interpretation stored per
   line so confirmations persist. Implementation: no line entities at all —
   `Recipe.ingredients` re-parses `ingredientsText` on every access; identity is a
   normalized-name lookup against the catalog (`IngredientCatalog.normalize` =
   trim + lowercase, plus a naive plural-suffix fallback). There is nothing a
   per-line confirmation or status could attach to.
2. **The kitchen-language problem is solved ahead of time, not at runtime.**
   Instead of shipping the full BLS (7,140 rows) plus a synonym table, a Python
   pipeline (`Scripts/nutrition/`) pre-translates the catalog into kitchen German:
   ~2,661 curated names with aliases, raw/cooked variants merged, colliding
   variants **averaged**. A legitimate alternative answer — but it costs exactly
   what the concept declares mandatory: **BLS identity is gone.** No BLS codes, no
   catalog names, no dataset version in the data; the join key is the name string.
   A renamed bundled name silently orphans the cook's aliases and custom values,
   and nobody can see which BLS entry (or average of how many) a number rests on —
   only a global "Quelle: BLS 4.0".
3. **Variants are aliases — the lossy "one line".** "Cocktailtomaten" *is*
   "Tomate" (one catalog entry, alias list). The shopping list shows "Tomate —
   700 g" and the variety information is swallowed — precisely what concept §14
   warns against. No variant relation, no sub-lines.
4. **The gram bridge is code, not data — and thin.** Generic hardcoded imprecise
   weights in `Nutrition/NutritionResolver.swift` (Prise 0.3 g, Zehe 5 g, Bund
   75 g, Portion 100 g, Pck. 250 g, Blatt 1 g); 18 hand-set `Stk.` weights in
   `nutrition.json`; **zero densities** — every volume converts at 1.0 g/ml, so
   "2 EL Olivenöl" computes as 30 g. User override exists for exactly one piece
   weight per ingredient; no "≈ assumption" labeling anywhere. "Tasse" is not a
   unit (parses into the name).
5. **Preparation states exist halfway.** `IngredientState {unspecified, raw,
   cooked}` lives in the type system and the bundled data (with fallback exact →
   raw → any), but **the parser never sets a state** — the raw/cooked potato case
   computes both lines as raw. TK/Konserve/getrocknet are separate catalog
   ingredients (pipeline `NONMERGE_WORDS`), not states. The only state UI is a
   read-only display picker in the ingredient form.
6. **Nutrition is cached, not a pure view.** Functionally close to derivation
   (content-hash invalidation, link-aware hashing, `invalidateAll` on catalog
   changes) but with real staleness holes: replacing the bundled data does **not**
   invalidate `StoredRecipeNutrition` (only the manual `readingVersion` bump
   would), and the single cache row per recipe lets two views at different serving
   counts thrash each other.

## 3 · Missing entirely

- **The status model** (open / proposed / confirmed) with candidate selection (the
  nine-Schmelzkäse picker), "deliberately without", and decision A's provisional
  marking. Today the implementation computes *unmarked-eager*: whatever happens to
  match flows in without comment. Matching itself is a pure lookup chain — no text
  search, no proposal, no confirmation.
- **The coverage report.** No "9 of 12", no gap reasons, no propagation through
  subrecipes — `NutritionAggregator.collect` silently `continue`s on unresolvable
  grams (`:60`) and missing nutrition (`:65`). Especially treacherous: an
  ingredient that *is* in the catalog but has **no nutrition entry** (35 curated
  names per the pipeline README, plus any own entry without numbers) is invisible —
  the "N Zutaten unbekannt" banner checks catalog membership only.
- **List reconciliation.** Later changes never reach an existing list (frozen keys,
  provenance by recipe *title* string, no recipe id); no "late addition", no
  "lapsed" annotation. The repaired-Ochsenherztomaten case dead-ends today.
- **List re-scaling** (concept §6, "Re-scaling on the list"): `ShoppingSource`
  stores pre-scaled quantities under a title, with neither recipe id nor captured
  portion count — re-scaling after the fact is unimplementable without the model
  change to plan entries (`portionenErfasst` / `portionenAktuell`) and
  captured-amount demands. The by-recipe view exists as the natural UI anchor.
- **Pantry staples** — no flag, no model, no section (repo-wide search confirms).
- **"Unassigned" prominence** — unknown names land in `.other` ("Sonstiges") at the
  *bottom* of the aisle order; the concept wants them on top, visible before the
  store.
- **"Unquantified" as a recognized category** — "Salz nach Geschmack" is merely a
  line without a number whose *name* contains the phrase; it fails catalog lookup
  and rides along as an unknown ingredient instead of recognized-without-amount.
- **BLS keys, dataset versioning, update reconciliation** — no orphan detection, no
  name-at-confirmation, no version stamp in data (the `"BLS 4.0"` source string is
  a hardcoded Swift constant).
- **Per-number provenance in the recipe** — the nutrition block says only "Pro
  Portion, geschätzt aus den Zutaten."; the basis of each line's contribution is
  visible nowhere (only the per-catalog-entry "Quelle:" footer).
- **Mixed-coverage accounting for own values** — own nutrition stores the 8 label
  fields and hardcodes the 8 micronutrients to 0, silently skewing micronutrient
  sums in recipes that mix BLS and own entries.

## 4 · Active contradictions (not gaps — opposing decisions)

1. **Check-off gets destroyed.** Re-adding a recipe to the list forcibly resets
   `isChecked = false` on the merged row ("adding something again means it is
   wanted again", `Shopping/SwiftDataShoppingListStore.swift:34`) — a direct breach
   of the concept's hard rule that user work is never reset. `clearChecked` also
   deletes rows outright.
2. **The NRF score.** The A–E `NRFBadge` per recipe is exactly the health verdict
   the concept rules out (§14: numbers with provenance, no score, no traffic
   light). This is a real decision to make later, not an oversight.
3. **Averaged variants.** Pre-averaging colliding BLS entries removes the choice
   the concept gives the cook (Schmelzkäse at 20% vs 60% fat is not a question
   with a mean).

## 5 · Implementation beyond the concept (must survive any migration)

- The entire **step-amount machinery**: `StepAmountResolver` (pots per group,
  backtracking assignment, remaining/fraction mentions), `AmountAIExtractor`
  (on-device FoundationModels, literal-text guard, model never picks the line),
  suggestion-only AI writes with `AmountReviewSheet` confirmation, per-recipe
  enrichment cache. The concept deliberately excluded instruction-text amounts;
  the implementation has a mature, guarded solution.
- **Ingredient groups** ("# Für den Teig") in the line grammar, used by pots and
  cook mode.
- **Cook mode** integration (resolved amounts inline, per-step ingredient lists),
  editor completion + amount-span coloring, the share extension reusing the whole
  unknown-ingredient flow, the by-recipe shopping view, manual list items parsed
  through the same parser.
- Two realities the concept must absorb:
  - **Comma-bearing catalog names** (974 of 2,661) force catalog-aware comma
    splitting in the parser — a wrinkle the concept did not foresee.
  - **The relationship-free, CloudKit-shaped schema** (everything joined by UUID /
    name string, every property defaulted). The concept's sketch with real
    relations must respect this once household sharing (VISION #10) arrives.

## 6 · Test-case scorecard

| Concept test case | Today | Verdict |
|---|---|---|
| 200 g Schmelzkäse | Pipeline-curated entry or unknown-banner; no candidate picker, no provenance, averaged values | fails |
| Veganes Hackfleisch | Own entry + own values; shopping unaffected | passes |
| 12 ingredients, 3 without values | Silent partial sum, no coverage line | fails |
| Ajvar ↔ "Ajvar Konserve" | One alias, applies everywhere | passes (provenance thin) |
| Tomaten + Cocktailtomaten | One line via alias — but variety info lost | partial (lossy) |
| 500 g raw / 300 g cooked potatoes | Both compute as raw; list shows no state annotation | fails |
| 1 Zehe Knoblauch | Generic 5 g in code; no ≈ label | partial |
| 2 EL Olivenöl | Water density → 30 g; no density data, no label | fails |
| Prise / nach Geschmack | Prise 0.3 g generic; "nach Geschmack" pollutes the name → unknown noise | partial |
| Ochsenherztomaten fixed after check-off | Line appears (own key), but the fix never reaches the existing list; re-adding un-checks | fails |
| Values added later, 20 recipes | `invalidateAll` on catalog change → recomputes | passes (hole: bundled-data update doesn't invalidate) |

---

*Findings are the state of the code at the snapshot above; nothing was changed. The
migration plan is a separate, later step.*
