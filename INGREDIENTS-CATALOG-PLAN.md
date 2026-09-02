# Catalog Plan

Companion to [INGREDIENTS-CATALOG.md](INGREDIENTS-CATALOG.md) (the target). Turns
its §3 into a sequence of shippable phases.

- **Status:** six of seven phases landed on the branch, none of them built or
  tested — see rule 6. Phase 6 is open; on review the order became 4 → 3 → 6,
  because phase 4 is what the cook asked for directly and phase 3 is what the
  round inferred.
- **Baseline:** `main` @ `44f3273`, 2026-09-01.
- **There is no existing user data.** Nothing is deployed, nothing has to be carried
  forward. That is not merely a relief — it removes a phase's worth of caution from
  every other phase, and it means the previous round's migration machinery is now
  dead weight that phase 0 takes out.
- **The five decisions stand unchanged.** Worth checking rather than assuming: none
  of them was shaped to dodge a migration. Depth uses a `parentID` that already
  exists, inheritance-as-proposal is computed, the Grundlage row is a form, the
  spice marker is shipped JSON, and dropping the bundling removes a view. They are
  what they would have been either way.

| Phase | What it buys | Size | |
| --- | --- | --- | --- |
| 0 — Take out what only the old data needed | ~500 lines and four entities gone | S | `3862979` |
| 1 — The basis becomes answerable | a mapping can be made, changed and searched | M | `416e010`, `80f9fa0` |
| 2 — Words with no values say so | the spices stop being a permanent gap | S | `257ba8f` |
| 3 — Inheritance becomes a proposal | the silent wrong numbers become visible | M | `00955d5` |
| 4 — The parent becomes something you can make | the relation gets a way in | M | `262ceb0` |
| 5 — The shopping list stops bundling | varieties are their own errands | S | `bc14811` |
| 6 — Category is inherited | one inheritance rule instead of an exception | S | open |

Phase 1 built decision C's three answers as strictly exclusive and left out the
"steht für" note the target had asked for; on review the cook chose the exclusive
form and the target was changed to match. Phase 2 marked 28 words rather than 29: checking each
against plausible catalog names instead of its own spelling turned up Chili, which
the source *does* have, filed as "Pfefferschote".

---

## 1 · Rules for the whole round

1. **The schema is free — so take the right shape, not the compatible one.** With no
   data to preserve, a stored field can change outright. None of the phases below
   needs that, but where the current shape only makes sense as a concession to data
   that no longer exists, it goes (phase 0). The inverse of the old rule, and it
   asks for the same alertness: notice when a design is being bent, and this time
   ask whether it is being bent for nothing.
2. **The tool before the question.** Phase 3 turns roughly four dozen silent
   inheritances into open questions. It should not ship before phase 1, which makes
   a question answerable, or phase 2, which removes the loudest unanswerable ones.
   With an empty store this is no longer a hard constraint — the questions only
   appear once recipes using those varieties exist — but it is still the order that
   makes each phase land as a repair instead of a chore.
3. **Every phase ships a working app.** Each closes named items of the target and
   leaves the rest alone.
4. **The cook's decision always outranks shipped data.** Phase 2 puts an answer in
   the bundle for the first time; it is a default, and an override must stay
   possible and obvious.
5. **Commits only on explicit request**, as everywhere in this repo.
6. **Verify what can be verified here, and say what cannot.** Off a Mac there
   is no build: SwiftData, SwiftUI and Core Data do not exist on Linux, and a
   Swift toolchain would not change that. `Scripts/parse_check.py` closes part
   of the gap — a real Swift grammar over every file, compared against the
   commit the work started from — and its own docstring is honest about the
   ceiling: it knows syntax, not types. Every phase below still owes a
   `swift test --package-path SousKit` and an app build on a Mac before it is
   finished.

## 2 · What this round retires

Decision E gives up the concept's grouped shopping entry (§6, "Bundling without
swallowing"). That is a deliberate reversal of a decided design, not an oversight,
and it has a record to keep straight:

- `ConceptScorecardTests` case 5 ("Tomaten + Cocktailtomaten") and case 10
  ("Ochsenherztomaten — never missing, and fixing it does not un-check the
  tomatoes") both assert the grouped entry. Case 5 changes meaning: the varieties
  stay distinguishable, which was the point, but as separate rows rather than as
  sub-lines of a total. Case 10's real subject is the late addition and the
  check-off that survives it — that part holds unchanged and must keep being
  asserted.
- `INGREDIENTS-CONCEPT.md` §6 gets a pointer to decision E, so the two documents do
  not quietly disagree.

Rewriting a scorecard case is the one thing in this plan that deserves a second
look before it happens. It is the record of a decision the cook made; changing it is
allowed only because the cook made the new one too.

## 3 · Phases

### Phase 0 — Take out what only the old data needed

*Closes nothing in the target. Enabled purely by there being no data, and worth
doing first because every later phase then touches less code.*

The previous round left two one-shot migrations and the legacy tables they read.
Both run at launch (`SousApp.swift:80-81`) against rows that cannot exist:

- `VocabularyMigration` / `SwiftDataVocabularyMigration` — folded four user tables
  into the vocabulary.
- `BundledDataMigration` / `SwiftDataBundledDataMigration` — re-keyed name-keyed
  user data onto SBLS codes.
- The four `@Model` types they exist to read: `StoredCatalogIngredient`,
  `StoredIngredientAliasOverride`, `StoredCatalogNutrition`, `StoredPantryFlag` —
  reachable from nothing else, and registered in the schema at
  `SwiftDataRecipeStore.swift:352-355`.
- Their tests: `BundledDataMigrationTests`, `LegacyStoreFixtures`, the legacy half
  of `VocabularyTests`.

Roughly 500 lines, plus four entities out of a schema that has to stay
CloudKit-shaped and is easier to reason about when everything in it is live.

One more thing the old data was paying for: `BasisAssignment.init(from:)` tolerates
a missing `status` and defaults it to `confirmed`, because a blob written before
there was a status had to keep working. Nothing has written such a blob. The
leniency can go, and a decode failure can become loud instead of silently
confirming a decision nobody made — its own doc comment already calls that the
worst case.

*Not in this phase:* `RecipeStoreMigration` (`SousApp.swift:343`). It copies a
household's library between stores, which reads like a live part of the sharing
architecture rather than a leftover. Whether it is still needed is its own question,
asked outside this round.

*Verification:* the suite passes with the files gone; the app launches against a
fresh store.

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

*Verification:* a test that a basis filed under one state can be re-pointed at
another row without touching the other states — `NutritionLibraryTests`, added after
the phase landed, since the phase itself shipped only the search tests.

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

*Closes target §1 finding 2 and decision A.*

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
  a recipe written with braune Champignons. `reindexSearch` exists for the
  upgrade case and has nothing to do here yet.

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

## 5 · The one open worry, downgraded

Phase 3 was the part of this round that could have felt like a chore: four dozen
inherited bases turning into open questions at once. With an empty store that
does not happen on the day it ships — the questions appear one at a time, as
recipes come to use those varieties, which is exactly when a question is worth
asking.

It comes back at import. The parked recipe rework will bring a large body of
recipes in one go, and with them a batch of open questions — but that same piece of
work is where the catalog gets curated properly, so the varieties should arrive
already mapped rather than inheriting. The two jobs cancel if they are done in that
order: curate first, import second.

The fallback stands if it turns out noisy anyway: mark inheritance as a proposal
only where child and parent sit in *different* BLS food groups, which catches
Staudensellerie and leaves Cocktailtomate alone. One more heuristic and one more
thing to explain, so it stays a fallback.
