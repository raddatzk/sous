# Word, Variety, Basis

A second round on [INGREDIENTS-CONCEPT.md](INGREDIENTS-CONCEPT.md), about the half
of it the cook actually touches: the ingredient catalog, the variety relation, and
the assignment of a BLS row.

- **Status:** decided — the five questions in §2 were resolved on 2026-09-01. Two of
  them were then revised the same day, by the question "so a parent is only there for
  nutrition, isn't it?" — which turned out to be the sharpest question of the round.
  §2½ records what it changed and why the obvious answer to it is wrong.
- **Scope:** the vocabulary model and the screens around it. The parser, the
  shopping list as a document, and the nutrition math are not reopened.
- **Why now:** the data layer does nearly everything the concept asks of it. The
  UI uncovers about half. Everything below follows from that one sentence.
- **The road:** [INGREDIENTS-CATALOG-PLAN.md](INGREDIENTS-CATALOG-PLAN.md) turns
  §3 into six shippable phases.

---

## 1 · What was found

Four findings, each checkable in the code as it stands.

### A working BLS mapping cannot be changed anywhere

In the recipe, a line of the coverage drill-down is only tappable while its
question is *open* or *proposed* (`Sous/Views/RecipeDetailView.swift:1068`,
`:1082`); a settled row is plain text. In the ingredient form, the section that
picks a catalog row appears only when `isNutritionEditable`
(`Sous/Views/IngredientCatalogView.swift:250`, `:792`) — which is false for
exactly those ingredients that already have values. The only route left is the
button "Eigene Werte eintragen", which is not what the cook wants when the numbers
are fine and the row behind them is wrong.

Concept §3 makes confirmation the cook's own work. Work that cannot be revised is
not a decision, it is a trap.

### The parent relation can be accepted, never chosen

`parentName` is written in two places only: a word-ending heuristic proposes one
while an ingredient is *coming into being* ("Als Sorte von Tomate führen?"), and a
"Lösen" button takes the relation back (`IngredientCatalogView.swift:383`). There
is no picker. Once the proposal is declined and the entry saved, the relation is
unreachable from inside the app.

`IngredientCatalogLibrary.setParent(_:of:)` exists and works. Only the way to it is
missing.

### There is no free search over the BLS

`IngredientBasisPicker` lists what `NutritionLibrary.candidates(forName:)` returns
— the curation's candidates, then a name search on the kitchen word, then the
parent's name, then the remembered name of an orphaned mapping, capped at 30. All
of it keyed off names the app already holds. A cook who knows the row they want and
whose word does not resemble it has no way to say so.

`BLSCatalog.search` is right there. Nothing offers it a query.

### The shipped data already breaks two of its own rules

`kitchen_words.json` holds a three-level chain — `Pilz → Champignon → Brauner
Champignon` — while the code, the docs and the store all say one level. It works by
luck: nutrition inheritance needs one hop here, and gets it.

And 29 root ingredients carry no BLS row at all, almost all of them spices:
Kurkuma, Zimt, Oregano, Kardamom, Safran, Lorbeer, Thymian, Rosmarin, Chili, Minze,
Koriander, Muskatnuss, Natron. Not an oversight in the curation — the BLS does not
list them. All 3,983 shipped rows were searched; the two hits for "Zimt" are
breakfast cereal with a cinnamon flavour, at 424 kcal.

So the picker offers a wrong answer rather than none, beside no free search and no
way to say "deliberately without" from that screen. That is three failures meeting
on one form, and it is where this round started.

### A variety inherits its parent's numbers silently, and sometimes wrongly

49 of the 60 varieties have no basis of their own and take their parent's
(`NutritionCatalog.swift:118`). Often that is right — Cocktailtomate is a tomato. Not
always, and nothing on screen says where the number came from, because a child
inherits the parent's *status* too, confirmation included.

Three cases where the correct row sits unused in the same shipped file:

| Word | Inherits | Correct row | Difference |
| --- | --- | --- | --- |
| Räucherlachs | Lachs roh, 32 mg sodium | `T410600` Lachs geräuchert, 1170 mg | ×37 |
| Trockenhefe | Backhefe frisch, 128 kcal | `R458000` Backhefe getrocknet, 334 kcal | ×2.6 |
| Staudensellerie | Knollensellerie roh, 30 kcal | `G660100` is a different plant; the right row is Bleichsellerie, 17 kcal | wrong food |

The reason none of them was mapped is the same one this whole round is about: the
kitchen word does not resemble the catalog word, and there is no free search.

### What was already right

The gram bridge is complete and needs nothing: `measures.json` ships seven generic
unit weights, 34 piece weights, 34 densities and group defaults, with a documented
resolution order, and the ingredient form lets the cook add or correct any of them
per unit ("Maß hinzufügen"). Inheritance of those weights from the parent already
works, merged per unit with the child winning.

---

## 2 · The decisions

### A · A parent is an ordinary ingredient, and a chain may be any depth

A parent is not a special kind of entry. It is a word that stands in recipes and
carries its own basis, and some other word happens to point at it. **Creating a new
parent is therefore not its own operation** — it is creating an ingredient, and then
pointing a child at it. That answers the question this round opened with: nothing
needs inventing, a picker needs building.

Depth is allowed because the data already wanted it. Inheritance walks up the chain
until it finds an answer, rather than taking exactly one hop.

*Price:* the one-level guard becomes a cycle check, in both stores that carry it —
`SwiftDataVocabularyStore.parentID(named:of:)` and its Core Data twin
(`CoreDataVocabularyStore.swift:171`). Both refuse a parent that is itself a variety,
and both refuse it *silently*, by returning nil, so the relation is dropped without
anyone being told. A cycle check has to refuse loudly.

*Rejected:* a parent as a pure grouping shell that never appears in a recipe and has
no values ("Reis" over Basmati and Jasmin). It would buy a tidier taxonomy and cost
a second kind of ingredient that the shopping list, the search and the form would
each have to tell apart. The app's two jobs do not need it.

### B · A variety inherits everything, and overrides field by field

Basis, unit weights, density, store, shelf note and pantry flag are inherited today.
**Category joins them**, and becomes optional on a child: set means overridden, empty
means inherited. One rule for every field instead of one rule with an exception.

The data agrees: of 60 varieties, **not one** differs from its parent's category, and
48 of the 49 varieties without their own BLS mapping do inherit one (the exception is
Pfefferminze under Minze, where the parent has none either).

**An inherited basis arrives as *proposed*, never as confirmed.** This is the one
correction the round made to itself, and it comes from asking what a parent is
actually for (see §2½). Inheritance is a good guess, not an answer: it is right for
Cocktailtomate and off by a factor of 37 for Räucherlachs, and today the child takes
the parent's confirmed status along with its numbers, which is what makes the bad
cases invisible. As a proposal it is still computed with — concept decision A — but
marked, counted as unconfirmed in the coverage, and asked about once.

Nothing new is needed for this: `NutritionBasis.Status` already has `proposed`, and
the whole clarification flow is built on it.

*Price:* `category` becomes optional in `kitchen_words.json` and in
`KitchenWords.Word`, and resolution walks the chain. The 60 redundant fields come out
of the data. Every recipe using one of the 49 inheriting varieties gains an open
question — which is the point, and which decision D's spice marker keeps from turning
into noise. The form has to say which values are inherited and from whom, rather
than showing them as though the ingredient owned them — which is also the honest fix
for the measures section, where a parent's piece weight is already displayed without
a word about where it comes from.

### C · The basis is one question with three answers

BLS row · own values · deliberately without. Three answers that exclude one another,
as `BasisAssignment` already models them — presented as one "Grundlage" row with a
switch, not as two form sections stacked with the exclusivity hidden in a footnote.
Where own values are chosen, the BLS row stays available beneath them as a note
("steht für …"), because that is what lets a data update still report the row as
gone.

The asymmetry stays and gets said out loud: **own values are a statement about the
ingredient, a catalog row is a statement about a state.** Typing numbers for
Kartoffel says what a potato is; picking a row says what a *cooked* potato is.

*Price:* the form and the picker have to write the same way. Today the form's basis
section always writes to `unspecified` — a mapping filed under `cooked` cannot be
repaired there at all.

*Rejected:* own values per state. It would be consistent, and it would put a state
switch above eight number fields for a case that arises when somebody copies a
packet label — where there is only ever one state.

### D · The curation may ship "no values, on purpose"

A curated word may declare that it has no basis and never will, with the reason in
the existing `via` field. Such a word stops counting as a gap in coverage, stops
being asked about, and — the point of the Zimt case — **stops being offered wrong
candidates**: a word that has been answered has no question for the picker to fill.

*Price:* this puts an answer in shipped data that concept §3 places with the cook.
It is defensible because the answer is the same for every cook and the app can be
overruled: a shipped "without" is a default, and the cook's own decision still wins,
including the decision to give Zimt values after all.

*Rejected for now:* real values for the spices out of a second source via
`community.json`. It stays possible — the file exists for exactly this — and the
door is left open for anything used by the tablespoon (Paprikapulver, Currypulver)
rather than the pinch.

### E · The parent does nothing on the shopping list

Varieties stop bundling under their parent. Champignon and Pfifferling are separate
rows, as they are separate things at the shelf — and because the list already sorts
by aisle, they stand next to each other anyway without a heading claiming they are
one purchase. `ShoppingLibrary.grouped(_:)` (`:530`), `ShoppingGroup` and the
sub-line rendering in `ShoppingListView.swift:214-241` go away.

*Price:* concept §6's grouped entry — "Tomate 700 g" with the cocktail tomatoes
readable underneath — is given up. That entry was designed to keep two things at
once, one place in the shop and a visible distinction. Aisle sorting turns out to
deliver the first well enough on its own, and the second is what actually matters
when standing in front of the shelf.

*It also dissolves a seam.* With no bundling, there is no middle word that is a
heading in one place and an item in another, so decision A's arbitrary depth costs
the shopping list nothing and `Pilz → Champignon → Brauner Champignon` can stay as
it is.

## 2½ · Why there is no second relation

The obvious reading of the mushroom case is that one relation is doing two jobs:
*variety-of* (Cocktailtomate of Tomate — the same product, more precisely) and
*belongs-to* (Champignon of Pilz — different products, one family). Splitting them
looks like the clean fix.

It is not, because **that distinction does not predict whether the numbers carry
over.** Räucherlachs is unambiguously a variety of Lachs and inherits its sodium
wrong by a factor of 37. Pfifferling under Pilz would be pure family grouping and
would inherit roughly right — 26 kcal against Champignon's 28. The line the cook
feels is real, but it runs through taste and shopping, not through nutrition.

So the three jobs are separated by three different means, not by a second field:

| Job | Answered by | Where |
| --- | --- | --- |
| Nutrition | inheritance as a *proposal* (decision B) | `NutritionCatalog.swift:118` |
| Shopping | nothing — no bundling (decision E) | `ShoppingLibrary.swift:530` |
| Finding recipes | the search index, walking the whole chain | `RecipeIndex.swift:22` |

The third already works and is the parent's least visible, most useful job: a recipe
with Hokkaido in it answers to "Kürbis". It takes exactly one hop today, so with
arbitrary depth it has to walk up to the root — otherwise "Pilz" does not find a
recipe written with braune Champignons.

---

## 3 · What follows

### Data

- `kitchen_words.json`: `category` becomes optional; drop it from the 60 varieties.
- `curation.json`: a "without values" marker; set it on the 29 spice words, each
  with its reason in `via`.
- `curation.json`: map the varieties whose inherited numbers are wrong and whose own
  row is already shipped — Räucherlachs, Trockenhefe, Staudensellerie for a start.
  The proposal status of decision B will surface the rest; this is the head start.
- `BundledDataTests`: every word without a basis either declares it or is reported;
  no cycle in the parent chain.

### Model

- Inheritance walks the chain (category, basis, measures, shopping fields), and an
  inherited basis comes back as `proposed`.
- The one-level guard in both vocabulary stores becomes a cycle check that refuses
  audibly.
- `KitchenWords.Word.category` optional; `CatalogIngredient.category` resolved, not
  stored.
- The curation's "without values" reaches `NutritionCatalog` as a settled basis, so
  coverage and the picker both see an answer rather than a gap.
- `RecipeIndex.ingredientKeys` indexes the whole ancestor chain, not one hop.
- `ShoppingLibrary.grouped(_:)` and `ShoppingGroup` go; `ShoppingListView` renders
  plain rows again.

### UI

Four gaps, all of which any target picture needed anyway:

1. **Pick a parent.** Suggestions from the name, plus free search — the shape
   `IngredientAliasPickerView` already has, with `setParent` at the end instead of
   `addAlias`. Reachable from the ingredient form at any time, not only at birth.
2. **A third exit for an unknown ingredient.** Beside "Neue Zutat" and "Schreibweise
   einer bekannten Zutat": "Sorte von …" — the same picker as (1). For recipe text
   this is the most common case of the three.
3. **Free search over the BLS** in the basis picker and in the form, under the
   proposed candidates.
4. **Change a settled mapping.** The "Grundlage" row of decision C is present and
   editable whatever the current state of the ingredient — including "bewusst ohne",
   which the form cannot say today.

---

## 4 · Deliberately not decided

- **Reworking the recipes to raw ingredients** ("geriebener Ingwer" → Ingwer, plus a
  step in the instructions) and the large catalog that would come out of it. Parked
  until the export is available; it is a data exercise, not a model question.
- **A de-minimis threshold in the coverage report** — concept decision C stands:
  retrofit it if the display proves noisy, and decision D above removes the loudest
  source of noise anyway.
- **Merging two ingredients** that turn out to be the same thing. Named in the
  concept as an ongoing cost of the vocabulary, still unbuilt, and not made worse by
  anything here.
- **Community values for the spices** — see decision D.
