# Catalog Plan

Companion to [INGREDIENTS-CATALOG.md](INGREDIENTS-CATALOG.md) (the target). Turns
its §3 into a sequence of shippable phases.

- **Status:** not started.
- **Baseline:** `main` @ `44f3273`, 2026-09-01.
- **Property worth stating first:** *no phase in this round migrates user data.*
  Everything the decisions touch is either shipped JSON (replaced wholesale on an
  update), a computed view, or a field the store already has. The vocabulary's
  `parentID` and `bases` exist; nothing new is persisted.

| Phase | What it buys | Size |
| --- | --- | --- |
| 1 — The basis becomes answerable | a mapping can be made, changed and searched | M |
| 2 — Words with no values say so | the spices stop being a permanent gap | S |
| 3 — Inheritance becomes a proposal | the silent wrong numbers become visible | M |
| 4 — The parent becomes something you can make | the relation gets a way in | M |
| 5 — The shopping list stops bundling | varieties are their own errands | S |
| 6 — Category is inherited | one inheritance rule instead of an exception | S |

---

## 1 · Rules for the whole round

1. **No schema migration.** If a phase finds itself wanting a new stored field,
   stop and re-read the target — the decisions were chosen to avoid one. The only
   store-side work is a search re-index in phase 4, and `RecipeStore.reindexSearch`
   already exists for exactly that.
2. **The tool before the question.** Phase 3 turns roughly four dozen silent
   inheritances into open questions. It must not ship before phase 1, which is what
   makes a question answerable, or before phase 2, which removes the loudest
   unanswerable ones. This ordering is the plan's one hard constraint.
3. **Every phase ships a working app.** Each closes named items of the target and
   leaves the rest alone.
4. **The cook's decision always outranks shipped data.** Phase 2 puts an answer in
   the bundle for the first time; it is a default, and an override must stay
   possible and obvious.
5. **Commits only on explicit request**, as everywhere in this repo.

## 2 · What this round retires

Decision E gives up the concept's grouped shopping entry (§6, "Bundling without
swallowing"). That is a deliberate reversal of a decided design, not an oversight,
and it has a record to keep straight:

- `ConceptScorecardTests` case 5 ("Tomaten + Cocktailtomaten — one place on the
  list, the varieties intact under it") and case 11 ("Ochsenherztomaten — never
  missing, and fixing it does not un-check the tomatoes") both assert the grouped
  entry. Case 5 changes meaning: the varieties stay distinguishable, which was the
  point, but as separate rows rather than as sub-lines of a total. Case 11's real
  subject is the late addition and the check-off that survives it — that part holds
  unchanged and must keep being asserted.
- `INGREDIENTS-CONCEPT.md` §6 gets a pointer to decision E, so the two documents do
  not quietly disagree.

Rewriting a scorecard case is the one thing in this plan that deserves a second
look before it happens. It is the record of a decision the cook made; changing it is
allowed only because the cook made the new one too.

## 3 · Phases

### Phase 1 — The basis becomes answerable

*Closes target §1 findings 1 and 3, decision C. No data change, no schema change.*

- The ingredient form's two nutrition sections become one **Grundlage** row with
  three answers — BLS row · own values · deliberately without — always present,
  whatever the ingredient currently has. Today the row picker is hidden for exactly
  those ingredients that already have values (`IngredientCatalogView.swift:250`).
- The form writes for the **state being viewed**, not always `unspecified`
  (`:792` and its `storedBasisCode`). A mapping filed under `cooked` becomes
  repairable there.
- **Free search over the BLS** under the proposed candidates, in the form and in
  `IngredientBasisPicker`. `BLSCatalog.search` already does the work; it needs a
  query and a field.
- The coverage drill-down in `RecipeDetailView` opens the picker for *settled*
  lines too (`:1068`, `:1082`), so a confirmed mapping can be revisited from the
  recipe as well.

*Verification:* a new test that every state of an ingredient with a confirmed basis
can be re-pointed at another row; `BasisStatusTests` extended for the per-state
write.

### Phase 2 — Words with no values say so

*Closes decision D. Shipped data + a small model change.*

- `curation.json` gains a marker for "no basis, on purpose", with the reason in the
  existing `via` field. Set on the 29 root words that have no BLS row —
  Kurkuma, Zimt, Oregano, Kardamom, Safran, Lorbeerblatt, Chili, Minze, Koriander,
  Muskatnuss, Natron and the rest of the spice shelf.
- The marker reaches `NutritionCatalog` as a settled basis, so coverage stops
  counting them as defects and the picker stops offering them candidates. Zimt is
  no longer shown breakfast cereal at 424 kcal.
- The cook can still give one of them values; the shipped answer is a default.

*Verification:* `BundledDataTests` — every kitchen word either has a target, or
declares it has none, or is reported by the build; nothing else is silently empty.

### Phase 3 — Inheritance becomes a proposal

*Closes decision B's nutrition half and target §1 finding 5. The loud one.*

- An inherited basis comes back as `proposed` rather than carrying the parent's
  status (`NutritionCatalog.swift:118`). It is still computed with — concept
  decision A — and now marked, counted as unconfirmed, and asked about once.
- Inheritance walks the whole ancestor chain instead of one hop.
- The ingredient form labels what is inherited and from whom, for the basis and for
  the piece weights the measures section currently shows as though they were the
  ingredient's own.
- **Ships with the head start:** `curation.json` gets its own rows for the three
  varieties whose inherited numbers are worst and whose correct row is already in
  `bls.json` — Räucherlachs (`T410600`), Trockenhefe (`R458000`), Staudensellerie
  (Bleichsellerie). Without this the three arrive as questions the cook has to
  answer for the app.

*Verification:* a test that a variety without its own basis reports `proposed` and
names its parent; `NutritionResolverTests` for the chain walk; the scorecard's
Cocktailtomate case gains the proposal status.

### Phase 4 — The parent becomes something you can make

*Closes target §1 finding 2 and decision A. No schema change; one re-index.*

- A **parent picker**: suggestions from the name plus free search, the shape
  `IngredientAliasPickerView` already has, calling `setParent` instead of
  `addAlias`. Reachable from the ingredient form at any time, not only while an
  ingredient is coming into being.
- The same picker becomes the **third exit** for an unknown ingredient, beside
  "Neue Zutat" and "Schreibweise einer bekannten Zutat": *"Sorte von …"*.
- The one-level guard becomes a **cycle check that refuses audibly** — in both
  stores (`VocabularyStore.swift:68`, `CoreDataVocabularyStore.swift:171`), where it
  currently drops the relation by returning nil and telling nobody.
- `RecipeIndex.ingredientKeys` indexes the **whole ancestor chain**, so "Pilz" finds
  a recipe written with braune Champignons. Needs one `reindexSearch` run on
  upgrade.

*Verification:* cycle refused and reported; a three-deep chain resolves basis,
category and search keys correctly; re-index covered by the existing store tests.

### Phase 5 — The shopping list stops bundling

*Closes decision E. Removes code; see §2 for what it costs.*

- `ShoppingLibrary.grouped(_:)` and `ShoppingGroup` go; `ShoppingListView.swift:214`
  through `:241` renders plain rows again. Varieties become their own errands, kept
  adjacent by the aisle sort rather than by a heading.
- Same-name merging across recipes is untouched — it goes by key, never by parent.
- Scorecard cases 5 and 11 are rewritten per §2.

*Independent of every other phase.* It can move earlier if the loss is wanted
sooner, or later if it wants to be judged on its own.

### Phase 6 — Category is inherited

*Closes decision B's identity half. Shipped data + resolution.*

- `category` becomes optional in `kitchen_words.json` and `KitchenWords.Word`;
  `CatalogIngredient.category` is resolved through the chain rather than stored.
- The 60 varieties drop the field they currently repeat from their parent — today
  not one of them differs from it.
- The form shows an inherited category as inherited, with an override that sets it.

*Verification:* `BundledDataTests` for the optional field decoding both shapes; a
test that an override wins and a cleared one falls back.

## 4 · Deliberately out of scope

- **The recipe rework and the large catalog** from the export — still parked, still
  a data exercise rather than a model question.
- **A second relation** for taxonomy — see target §2½ for why it does not solve what
  it looks like it solves.
- **Merging two ingredients** that turn out to be the same thing. Named as an
  ongoing cost in the concept, still unbuilt, untouched here.
- **Community values for the spices** — phase 2 makes their absence honest; giving
  them real numbers stays a separate, later question.

## 5 · The one open worry

Phase 3 hands the cook roughly four dozen questions at once. Phases 1 and 2 are
sequenced ahead of it precisely to blunt that, and the three curated rows take the
worst cases off the pile — but the number is still large, and it is the only part of
this round that could feel like a chore rather than a repair.

If it does, the fallback is to mark inheritance as a proposal only where child and
parent sit in *different* BLS food groups, which would catch Staudensellerie and
leave Cocktailtomate alone. It is one more heuristic and one more thing to explain,
so it stays a fallback rather than the plan.
