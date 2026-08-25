# Line, Ingredient, Number

A concept for ingredients, shopping list, and nutrition in Sous — from the free-form
ingredient line to an honest per-portion number.

- **Status:** decided — the four trade-offs in §12 were resolved on 2026-08-25.
- **Provenance:** written deliberately blind to the existing implementation, as an
  independent design. A concept-vs-implementation diff is the next step; migration is
  explicitly out of scope here.
- **Nutrition source:** Bundeslebensmittelschlüssel (BLS) 4.0, Max Rubner-Institut,
  ~7,140 entries, values per 100 g, CC BY 4.0 (attribution + change note required).
- **German original** (as reviewed): https://claude.ai/code/artifact/15c801e1-969c-4bab-bb1e-702ceb4bd335

---

## 1 · Guiding principles

Five principles carry the whole design. Everything else is a consequence.

### I. The recipe text is untouchable

What the cook writes stays verbatim. Recognition is an *interpretation layer next to*
the text, never a rewrite. The app must never turn "200 g Schmelzkäse" into
"200 g Schmelzkäse aus Frischkäse, streichfähig, mind. 60 % Fett i. Tr." — neither in
the recipe nor on the shopping list. The price: the app manages two things everywhere
(text and interpretation) and must keep them consistent when the text changes.

### II. Failures fall toward visibility

A line the app does not understand *still shows up* — as raw text on the shopping list
(better one puzzling entry than one missing article) and as a named gap in the
nutrition sum (better "9 of 12 ingredients" than a smooth, wrong number).
Non-recognition is a visible state, not a silent omission.

### III. Shopping list and nutrition fail independently

The shopping list only needs to know *what is being talked about*. The nutrition
computation additionally needs a data basis and a gram equivalent. "Veganes
Hackfleisch" is therefore a nutrition problem but not a shopping problem — and the
design ensures the one never blocks the other.

### IV. Guessing is allowed where the error is small and visible

Putting a tablespoon of oil at ≈ 10 g is a small, openly labeled assumption — the app
makes it on its own. Silently picking the wrong one of nine processed-cheese variants
can triple the fat figure without anyone noticing — the app does not decide that
alone. The boundary is not between "guess" and "ask" but between assumptions with a
small, visible error and those with a large, invisible one.

### V. Nutrition is derivation; the shopping list is a document

Nutrition sums are *never stored* — they are computed from the current mappings at
every display. When the cook adds values later, all twenty recipes are correct
immediately; there is no stale intermediate state to fix. The shopping list, by
contrast, carries user work (checking items off) and is therefore a snapshot with
controlled reconciliation, not a live view. This asymmetry is deliberate and directly
resolves two of the test cases.

## 2 · Three concepts instead of one

The core of the design is a separation that untangles nearly all test cases: **what
the cook wrote, what they are talking about, and what the math uses are three
different things.**

```
Ingredient line ──parser+vocabulary──▶ Ingredient ──mapping, confirmed──▶ Nutrition basis
"200 g Schmelzkäse"                    Schmelzkäse                        "Schmelzkäse, mind. 45 % Fett i. Tr." (BLS)
free text in the recipe,               the cook's-language term;          a BLS entry or custom values, per 100 g;
kept verbatim                          identity across recipes;           visible as fine print,
                                       what the shopping list shows       never as a display name
```

The **ingredient line** belongs to the recipe. The **ingredient** is an entry in the
cook's personal vocabulary: "Tomaten", "Ajvar", "veganes Hackfleisch". It comes into
being implicitly through writing — whoever types "Ajvar" for the first time has an
ingredient "Ajvar" afterwards, whether they notice or not. Everything that should hold
across recipes hangs off this ingredient: aliases and spelling variants, the mapping
to a nutrition basis, unit knowledge ("1 Zehe ≈ 3 g"), the store section, a pantry
flag. When two recipes write "Tomaten", they mean *the same* ingredient — that is the
foundation of any merging on the shopping list.

The **nutrition basis**, finally, is what a number rests on: either a reference to a
BLS entry or a custom value set entered by the cook. It is deliberately attached *per
ingredient*, not per line: whoever maps Ajvar to the BLS entry "Ajvar Konserve" once
has done it for every recipe — the mapping work amortizes.

**Rationale:** without the middle layer, every line would have to point directly at
the catalog. Catalog language would end up on the shopping list, every mapping would
have to be repeated per recipe, and "Tomaten" from two recipes would share no
identity. **Price:** the vocabulary is its own data set that wants maintenance —
typos create duplicates, so there must be a merge operation and silent cleanup of
unused, never-confirmed entries. That is ongoing complexity, but it sits in one place
instead of in every recipe.

### Variants

Ingredients can stand in a flat relation: "Cocktailtomaten" and "Ochsenherztomaten"
are *variants of* "Tomaten". A variant inherits the parent's nutrition basis and unit
knowledge as long as it has nothing of its own, and the shopping list groups variants
under the parent — without swallowing the distinction (§6). The app proposes the
relation at the moment a new ingredient comes into being (a single, casual prompt:
"treat as a variant of Tomaten?"), using a word-ending heuristic rather than bare
substring containment — that catches German compounds and avoids most false friends
("Erdnussbutter" is not a butter variant). It never groups silently (decision B, §12).
The relation is deliberately one level deep; a taxonomy ("nightshades") would be
maintenance cost with no benefit to the app's two jobs.

### Preparation states

That the BLS lists "Kartoffel geschält, roh" and "Kartoffel geschält, gekocht" as
separate rows is not a nuisance but a correct observation: the state belongs to the
*use*, not to the ingredient. So the ingredient line optionally carries a state (raw,
cooked, fried, frozen, canned, dried — a small closed vocabulary the parser reads from
words like "gegart" or "TK"). The ingredient holds one basis mapping per state, plus a
default state for lines without one — normally "raw / as purchased". Thus 500 g raw
and 300 g cooked potatoes compute with different values yet remain one ingredient.

## 3 · Recognition and mapping

Between line and number lie two translations of very different nature — and the design
treats them differently.

**The first translation is grammar:** number, fraction ("½"), range ("1–2"), unit
(g, kg, ml, EL, TL, Prise, Zehe, Bund, Stück …), parenthetical note ("(rot)"), state
words, the phrases "nach Geschmack" / "nach Belieben", and the recipe reference. That
is a closed, small piece of language — a deterministic parser works here, deciding the
same way every time, with reproducible failures. Whatever remains after subtracting
amount, unit, and notes is the name candidate.

**The second translation is open language:** from name candidate to ingredient
(normalizing case and singular/plural against the vocabulary including aliases), and
above all from ingredient to BLS entry. The latter is the genuinely hard part, because
kitchen German and catalog German are nearly disjoint: the cook writes
"Süßkartoffel", the catalog says "Batate/Süßkartoffel"; the cook writes
"Schmelzkäse", the catalog knows nine refinements of it. This is bridged by a
**shipped, curated synonym table** (common kitchen word → BLS candidates), plus
normalized full-text search over catalog names. It is app data like the BLS itself,
the single biggest lever for hit rate — and a permanent curation cost (§10).

### The status model

Every mapping of an ingredient to a basis has three states, with the same meaning
everywhere in the UI:

- **open** — no basis. The ingredient is fully functional on the shopping list, and a
  named gap in nutrition sums.
- **proposed** — the app has a candidate via synonym table and search; the cook has
  not touched it yet. Sums *are* computed with proposed bases, provisionally and
  unmistakably marked (decision A, §12).
- **confirmed** — the cook accepted the candidate, chose another, or entered custom
  values. Only this is a solid foundation.

The status becomes visible first *in the recipe itself*: a subtle marker on the line
(e.g. a dotted underline of the name) says "something is open here"; tapping it opens
the candidate list — the nine Schmelzkäse entries, "enter custom values",
"deliberately without nutrition". The recipe is the earliest place the cook can notice
a gap, long before a sum or a list would be wrong. The third option matters:
*"deliberately without"* is a confirmed state, not a perpetual warning. Whoever
decided that veganes Hackfleisch stays without values must not be nagged on every
open.

A line's interpretation (amount, unit, ingredient reference, state) is **stored, not
re-guessed at every display** — confirmations are the cook's work and must not decay.
When the line text changes, it is re-parsed; confirmations survive exactly where the
affected part stayed unchanged ("300 g Tomaten" → "400 g Tomaten": ingredient mapping
stays, amount is new; "Tomaten" → "Ochsenherztomaten": the mapping falls back to
*open*).

## 4 · The gram bridge

The BLS computes per 100 g; the kitchen computes in tablespoons, cloves, and pinches —
and the source ships neither piece weights nor densities. A second shipped table fills
this gap: the **measure table**. It maps (unit, ingredient or food group) to grams:
"1 EL Öl ≈ 10 g", "1 Zehe Knoblauch ≈ 3 g", "1 Zwiebel ≈ 90 g", "1 Prise ≈ 0.3 g".
Specific entries beat group defaults; the cook can override any value on their
ingredient ("my onions are bigger").

All these values are **assumptions and displayed as such** — the nutrition detail
shows "2 EL ≈ 20 g (assumption)", tappable and correctable. Per principle IV this is
permitted guessing: the error is small (whether the tablespoon holds 10 or 14 g barely
moves an orientation figure) and visible (the ≈ sits right there). That oil is lighter
than water is thus no special case but simply a table entry: volume units translate
differently per ingredient or group; no explicit density model is needed. **Price:**
this table is curation work too, and it will never be complete — a unit without an
entry then becomes its own named gap reason in the nutrition coverage ("no gram
equivalent for '1 Bund'").

Amounts *without* a number — "nach Geschmack", "etwas", "1 Prise" without a usable
weight — are their own *recognized* category: the line is fully understood, it just
deliberately carries no accountable amount. Such lines do not count as a defect in the
coverage display, appear in the detail as "not included", and do not scale (which for
"Salz nach Geschmack" is exactly right).

## 5 · Nutrition as derivation

The math itself is trivial once the layers stand: per line
`grams × basis values / 100 g`, summed, divided by the portion count. Everything
around it is what matters.

**Nothing is stored.** The sum is a view over the current state of interpretations,
mappings, and the measure table. At this data size (dozens of lines, in-memory access
to 7,140 BLS rows) it is instantly computable at any time. That dissolves the test
case "cook adds values later, twenty recipes already showed numbers": there are no
twenty stored numbers, only twenty views that show the new state on next open. The
price of this principle is real but lies elsewhere: the app must never treat derived
numbers as a *record*. A food diary ("what did I eat on March 12") would be built
wrongly on retroactively changing numbers — which is why it is outside this concept
(§11).

**Every sum carries a coverage report.** A nutrition figure never appears naked, but
always with its basis: *"≈ 640 kcal per portion — 9 of 12 ingredients included."* The
detail behind it lists every line with its contribution and its gap reason: "no
basis", "no gram equivalent", "basis only proposed", or neutrally "no amount, not
included". Lines without a gram equivalent count as gaps, but with their own label —
the remedies differ ("no measure known" vs "no nutrition basis"), so the reasons must
be distinguishable; no de-minimis threshold for now, retrofittable if the display
proves noisy in practice (decision C, §12). Every entry is the direct jump-off point
to the fix. The number is thereby as honest as an incomplete number can be: it says
what it knows and what it doesn't. A coverage measure by mass share instead of
ingredient count is deliberately omitted — it would be more precise but itself hangs
on the gram assumptions and explains itself worse to the cook; the expandable list of
gaps does more than a second percentage would.

**A small nutrient set is displayed** — energy, fat, of which saturated,
carbohydrates, of which sugar, fiber, protein, salt. The BLS ships well over a hundred
columns, and internally they are kept; but the job is orientation, and the cook's
custom values (typically copied from a package label, where exactly this set appears)
must be able to stand comparably next to BLS values. Whoever enters only energy and
protein for veganes Hackfleisch gets a sum in which the other columns are reported as
gaps for that ingredient — the same coverage principle, one level deeper.

### Subrecipes

"1 Portion [Naan]" is a line whose ingredient is a recipe. For nutrition: total values
of the Naan recipe divided by its portion count, times the factor — recursively, with
cycle detection (A references B references A: the line is marked as an error and
treated like an unaccounted one, visible per principle II). Crucially, **the coverage
report propagates.** If the Naan recipe has a gap, the curry embedding it has the same
gap — reported as "from Naan: 1 ingredient without values". Without this
pass-through, subrecipes would become honesty holes. Subrecipe lines support only
"Portion" as their unit; "200 g Naan-Teig" would need the subrecipe's total mass,
which inherits every gram assumption — deliberately unsolved (§11).

### Scaling

Scaling acts on the *interpretation*, never on the text: quantified amounts are
multiplied and overlaid over the original value in the display; piece counts render as
clean fractions ("1½ Zwiebeln"). Unquantified amounts do not scale and remain
verbatim — correct for "Salz nach Geschmack", at least visible for everything else. An
unparsed line cannot scale; it stays unchanged and carries the same marker that flags
it as unrecognized anyway. Per-portion nutrition is invariant under scaling; the
shopping list takes the scaled amounts. Amounts inside the instruction prose are not
covered by this concept.

## 6 · The shopping list as a document

A shopping list arises from a selection of recipes with portion factors. Generation:
collect all ingredient lines, recursively resolve subrecipes into their lines (the
Naan line *means* flour and yeast), scale, then bundle by ingredient. From that moment
the list is a **document with its own state** — it belongs to the cook standing in the
store, not to the recipes anymore.

### Bundling without swallowing

Bundling goes by ingredient identity, grouping by the variant relation. Within an
entry only *equal units* are summed; different ones stand side by side ("Tomaten —
500 g + 2 Stück"). Forced conversion via the measure table would be possible but is
the wrong direction: for the orientation figure of nutrition, assumptions are good
enough; on the list they would destroy the recipes' handwriting — the cook thought
"2 Stück", not "180 g". Variants appear as sub-lines of their parent:

```
Tomaten                     700 g
  ├─ 500 g  (Bauernsalat)
  └─ 200 g Cocktailtomaten  (Pastasalat)
```

One line in the sense of "one place on the list", but never silent unification of
different products — whoever needs 200 g Cocktailtomaten must not lose them as an
anonymous part of "700 g Tomaten". States are ignored in bundling but annotated:
"Kartoffeln — 500 g + 300 g (weighed cooked)". You buy raw; how much raw yields 300 g
cooked, the source does not know, and the list does not pretend to (no yield factor,
§11).

### The path through the store

Sorting is by store sections (produce, dairy, canned, baking …). The seed comes from a
small shipped mapping of BLS food groups to sections — the groups are a nutrition
taxonomy, not store logic, but serviceable as a first sort. The cook can reassign the
section per ingredient and reorder sections to match their store; both are ingredient
or user settings, not list settings. Two special sections: **"Unassigned"** sits at
the very top and collects raw-text lines the app could not interpret — prominent, so
they surface before the store, not in it. **"Pantry"** sits collapsed at the end:
ingredients with the pantry flag (salt, oil, flour) land there as a check-through list
instead of among the real errands. The cook sets the flag; the app at most suggests
it.

### Updating without destroying

When something upstream changes — a recipe is edited, a mapping repaired, a factor
changed — the list is not regenerated but **reconciled**, under one hard rule:
*checking off is the cook's work and is never reset.* Demands are traceable (every
list entry knows which lines of which recipes it stems from); new demand is appended
as a new, open item marked "late addition" — even under an ingredient already checked
off. Lapsed demand is rendered struck through rather than deleted when the item was
already checked. The list thus honestly tells what changed since the check-off,
instead of pretending it had always been right.

### Re-scaling on the list

The cook usually adds a recipe at whatever scale the recipe view currently shows —
so the plan entry captures that portion count at add time. It stays adjustable
afterwards: the by-recipe view of the list shows each recipe with its portion count,
and changing it re-derives that recipe's demands.

Two rules make this safe. First, re-scaling computes from the *captured* demands,
never by re-reading the recipe: every demand carries its amount together with the
portion count it was captured at; the effective amount is captured ×
current/captured. The snapshot property survives — a recipe edited in the meantime
still does not leak into the list; only the scale changes. Second, the
reconciliation rules above apply unchanged: demands on unchecked items adjust in
place (no user work is touched); on checked items an increase appends the difference
as a new, open, late-addition-marked row, and a decrease is annotated on the checked
row rather than un-checking anything. Unquantified and raw-text demands do not
scale, as everywhere else.

Price: the plan entry becomes a mutable part of the document, and every demand must
carry its capture scale — slightly heavier than frozen amounts, but exactly what
turns "actually, only half of it" into one tap instead of delete-and-re-add.

## 7 · Custom data and BLS updates

There are two data worlds, and the boundary between them is the model's most important
invariant:

- **Shipped, immutable, replaceable on app updates:** the BLS table, the synonym
  table, the measure table, the section defaults.
- **User data, persistent:** recipes, line interpretations, the ingredient vocabulary
  with all mappings and overrides, custom nutrition values, shopping lists.

User data references the shipped world **exclusively via the BLS entry's domain key
stored as a value** — never as a persistence-framework object relationship. Only then
can the bundle be swapped wholesale on update without touching user data. Every
confirmed mapping additionally stores the catalog name at confirmation time and the
BLS version of that moment.

After an update a **reconciliation pass** runs: keys that still exist remain valid —
changed values flow silently into the (derived anyway) sums, with no notice; only a
line in the sources screen ("data state: BLS 4.0.x, updated …") leaves a trace
(decision D, §12). Vanished keys set the mapping to *orphaned*: the app shows the
remembered old name ("was based on: Kartoffel geschält, gekocht — no longer contained
in the updated source"), proposes a successor via the synonym table, and treats the
ingredient as a gap until re-confirmation.

Custom nutrition values are their own record per ingredient (values per 100 g plus a
free source note, e.g. "package, brand X") and rank fully equal to a BLS reference as
a basis — same status mechanics, same visibility of the foundation ("source: own
entry"). The CC-BY duties are met by a sources screen: attribution (BLS 4.0, Max
Rubner-Institut, license) and the change note that the data was reshaped for the app
and augmented with synonyms and measures; additionally every basis display names its
origin ("source: BLS").

## 8 · Data model sketch

Entities and load-bearing fields, no persistence details. Between the two worlds only
value references (`↪ key`), never framework relationships.

### User data (SwiftData, persistent — survives every app update)

- **Rezept** — `titel`, `zubereitung` (free text), `portionen` (base for scaling),
  `zeilen` [Zutatenzeile], ordered.
- **Zutatenzeile** — `rohtext` (verbatim, untouchable); interpretation: `menge?`,
  `einheit?`, `mengenart` (quantified · unquantified · none); `zutat?` → Zutat *or*
  `teilrezept?` → Rezept + factor; `zustand?` (raw, cooked, frozen, canned …),
  `zusatz?` ("(rot)"); `deutungsstatus` (unrecognized · proposed · confirmed).
- **Zutat** (vocabulary) — `anzeigename`, `aliasse` [text]; `varianteVon?` → Zutat
  (one level); `vorrat` (bool), `ladenbereich?`; `masse` [(unit, grams, origin:
  default · own)]; `basen` [(state, Nährwertbasis)] + `standardzustand`.
- **Nährwertbasis** — either `blsVerweis`: ↪ key, `nameBeiBestätigung`,
  `blsVersion`, `status` (proposed · confirmed · orphaned); or `eigeneWerte`: per
  100 g (energy, fat, saturated, carbs, sugar, fiber, protein, salt — partial sets
  allowed), `quellnotiz`; or `bewusstOhne` (confirmed opt-out).
- **Einkaufsliste** — `erstellt`, `plan` [Planposten], `posten` [Listenposten].
- **Planposten** — → Rezept; `portionenErfasst` (portion count at add time — the
  scale the cook was viewing); `portionenAktuell` (mutable; re-scaling on the list
  edits this and triggers reconciliation).
- **Listenposten** — `zutat?` → Zutat *or* `rohtext` (unrecognized line); `bedarfe`
  [(amount as captured, unit, state?, origin: Planposten/line)] — effective amount
  = captured × `portionenAktuell`/`portionenErfasst` of the origin Planposten;
  `abgehakt` (bool), `nachträglich` (bool), `entfallen` (bool).

### Shipped data (bundle, read-only — replaced wholesale on app updates)

- **BLS-Eintrag** — `schlüssel` (the source's domain code), `name` (catalog
  designation), `gruppe`, values per 100 g (full column set; the small set is what
  gets displayed).
- **Synonymtabelle** — `küchenwort` → [BLS keys, weighted]; curated; the biggest
  hit-rate lever.
- **Maßtabelle** — (`einheit`, `bezug`: BLS key or group) → `gramm`; EL, TL, Prise,
  Zehe, Stück, Bund, Tasse …; always labeled an assumption, overridable per
  ingredient.
- **Bereichs-Defaults** — `gruppe` → store section (seed sorting).
- **Quellenangabe** — BLS version, CC BY 4.0 license text, change note.

Not in the model: computed nutrition sums (pure views, principle V) and any global
"recognition cache" (the interpretation lives on the line, where it belongs). The two
derived artifacts of the app are deliberately built differently: the nutrition sum as
an ephemeral view, the shopping list as a materialized document with reconciliation —
because only the latter carries user state.

## 9 · The test cases, played through

**"200 g Schmelzkäse"** — Recipe: the line stands verbatim; the name carries the
*proposed* marker with the best candidate from the synonym table; a tap shows all nine
variants, "custom values", "deliberately without". List: "Schmelzkäse — 200 g";
catalog language never reaches the list. Nutrition: computed provisionally with the
proposed basis, visibly marked ("based on: Schmelzkäse, mind. 45 % Fett i. Tr. —
unconfirmed"), the foundation tappable in the detail (decision A).

**"500 g veganes Hackfleisch"** — the ingredient enters the vocabulary like any other;
the list carries it immediately (principle III). BLS search yields nothing usable —
the mapping stays *open*, the sum reports the gap. The cook types the label values in
as a custom basis or confirms "deliberately without"; either ends the notice for good.

**Twelve ingredients, three without values** — shown is the sum of the nine, never
naked: "≈ 640 kcal per portion — 9 of 12 ingredients included", behind it the three
missing ones with reason and jump-off to the fix. The number is honest because it
speaks its own incompleteness; a silent "640" would be a lie by omission.

**Ajvar, cooked regularly** — confirm "Ajvar Konserve" as basis once — on the
ingredient, not the line. From then on it holds in every recipe that writes "Ajvar".
The display name stays "Ajvar"; "Ajvar Konserve" appears only as the fine print of
the foundation.

**"Tomaten" + "Cocktailtomaten"** — the app proposes the variant relation (name
kinship), the cook confirms once. On the list: one grouped entry "Tomaten — 700 g"
with sub-lines that keep the 200 g Cocktailtomaten distinguishable (see §14 on the
original phrasing "one line").

**500 g raw / 300 g cooked potatoes** — Nutrition: two states, two bases: 500 g × raw,
300 g × cooked — exactly what the BLS keeps separate rows for. List: one entry
"Kartoffeln — 500 g + 300 g (weighed cooked)". No conversion, because the source knows
no cooking yield, and an invented number would violate principle IV. The human at the
shelf rounds up.

**"1 Zehe Knoblauch"** — Nutrition: measure table, 1 Zehe ≈ 3 g, labeled an
assumption. List: "Knoblauch — 1 Zehe". Translation into purchase units ("one bulb")
is deliberately out of scope (§11) — the human knows cloves aren't sold singly.

**"2 EL Olivenöl"** — no density model, a table entry: "EL" for oils ≈ 10 g, so
≈ 20 g in the math, with ≈ and tappable. That oil is lighter than water lives in the
entry, not in a formula.

**"1 Prise Salz" · "Salz nach Geschmack"** — fully recognized, amount kind
"unquantified": no coverage defect, shown in the detail as "not included", does not
scale. On the list, salt — as a pantry ingredient — lands in the collapsed pantry
check-through, not among the errands.

**Ochsenherztomaten, fixed after checking off** — before the fix the line sat as a
raw-text entry under "Unassigned" — it was never missing (principle II). The cook
creates "Ochsenherztomaten" as a variant of "Tomaten"; reconciliation appends the
demand as a *new, open, late-addition-marked* item under the Tomaten entry. The check
mark on the already-bought tomatoes stays untouched — the group shows: done, but
something arrived later.

**Values added later, twenty recipes** — a non-event. Sums are views (principle V);
the twenty recipes show the new state on next open, and the coverage display improves
everywhere by itself. There is no stored old value that could go stale.

## 10 · The hardest parts

**1. Kitchen German vs. catalog German.** Mapping open language onto 7,140 catalog
names is the core difficulty — everything else is bookkeeping. No algorithm reliably
turns "Schmelzkäse" into the right one of nine variants, because the information
simply isn't in the line. The design answers threefold: curated synonym table
(diligence work that is never finished), confirmation per ingredient instead of per
line (the work amortizes), and the status model (uncertainty is a visible state, not a
silent error). The rest is hit rate, not correctness — and that is the right target.

**2. The gram bridge.** Between "2 EL", "1 Zehe", "1 Zwiebel" and "per 100 g" lies a
data gap the source cannot close in principle. The measure table is an honest crutch:
good enough for orientation, openly declared an assumption, overridable. Curating it
cleanly — which units, which group defaults, which exceptions — is more tedious than
it looks.

**3. Reconciliation under ongoing user work.** Twice, changing sources meet performed
work: BLS update vs. confirmed mappings, and recipe edits vs. checked-off lists. Both
need the same discipline — user work is untouchable; changes are appended and marked,
not folded in — and both are rich in edge cases (orphaned keys, lapsed demand, renamed
ingredients) that must be thought through individually.

**4. The cold start.** A freshly imported recipe with fifteen ingredients produces
fifteen mapping decisions. If the app demands them all at once, it feels like a form,
not a cookbook; if it stays silent, nutrition never happens. Decision A defuses the
worst of it — provisional numbers appear immediately — but the balance remains a
design task: casual markers in the recipe, a collected "5 ingredients to clarify"
view, never a modal. It decides the fate of the whole nutrition feature.

**5. Honesty that doesn't nag.** Principle II produces many visible states. The art
is dosage: gaps must be findable without the app constantly peddling its own limits.
The confirmed state "deliberately without" is the most important valve — it separates
the cook's decision from the app's weakness.

## 11 · Deliberately not solved

- **Purchase units and package sizes.** The list carries demands ("1 Zehe", "700 g"),
  not packages ("1 bulb", "2 packs of 500 g"). Package knowledge is store- and
  brand-dependent and a bottomless data-maintenance pit; the human at the shelf solves
  it in passing.
- **Cooking yield.** No raw ↔ cooked conversion; the list annotates instead of
  computing. A curated yield table would be a possible later extension of the same
  mechanism as the measure table.
- **Amounts in instruction prose.** Scaling and accounting act on the ingredient
  list; numbers in the preparation text stay outside.
- **Food diary and daily balances.** Retroactively changing views (principle V) are
  incompatible with record-keeping; that would be its own concept with frozen
  snapshots.
- **External product data** (barcode, Open Food Facts) as a source for branded
  products like the vegan ground meat — architecturally connectable as another basis
  kind, not designed here.
- **Subrecipes in units other than portions** ("200 g Naan-Teig") — would need the
  subrecipe's total mass and thus inherit every gram assumption; only sensible once
  the measure table has proven itself.
- **Multilinguality.** Parser, synonym table, and normalization are German; the model
  does not prevent a later second language, but it is not co-designed.
- **Compound lines** like "Salz und Pfeffer" — see §14.

## 12 · Resolved trade-offs

Four decisions that were genuinely open; resolved 2026-08-25 (the cook's call,
following the recommendations). The rejected option and both prices are kept on
record.

**A — Compute with proposed mappings? → Yes, provisionally and unmistakably.**
Computing only after confirmation would make every number solid, but before the first
maintenance session there would simply be no nutrition; the feature would look broken,
and the incentive to confirm fifteen mappings is low when nothing shows for it. So:
provisional numbers immediately, with their own typography, a coverage line naming
"of which 4 unconfirmed", and confirmation as a batch flow with one tap per
ingredient. The objection to silent guessing hits the *silent* — not the open,
insistent kind. Price paid: numbers based on unchecked conjectures are in the room
(the Schmelzkäse guess can be off by 3× in fat), and markers can dull with habit —
which is why the marking must never become subtle.

**B — Variant grouping: propose or manual only? → Propose, at creation time only.**
Name-kinship proposals ("Cocktailtomaten" contains "Tomaten") make grouping nearly
free; the price is false friends eroding trust. Contained: the proposal appears only
in the single, casual moment a new ingredient comes into being ("treat as a variant
of Tomaten?"), uses a word-ending heuristic instead of bare containment (German
compounds end in their head noun — "Erdnussbutter" is caught, most false friends are
not), and silent grouping never happens. Price paid: the list stays split wherever
the cook dismisses or never sees the prompt.

**C — Lines without a gram equivalent in the coverage display? → Count as gaps,
separately labeled.** Treating "1 Bund Petersilie" like an unquantified line would
keep the display calm, but a real gap ("3 Stück Hähnchenbrust" without a piece
weight) would vanish into the same pot. So they count as gaps, with their own label
("no measure known" vs. "no nutrition basis") because the remedies differ. No
de-minimis threshold for now — retrofittable if practice shows the display drowning
in parsley. Price paid: coverage lines will sometimes be dominated by trifles that
barely move the sum.

**D — BLS update changes values of existing mappings: notify or silent? → Silent.**
Consistent for an orientation figure; nobody wants to read "potatoes now have 2 kcal
less". Only orphaned keys — which demand action anyway — are actively reported. A
line in the sources screen ("data state: BLS 4.0.x, updated …") remains as the
trace. Price paid: whoever memorized a number sees a different one without comment.

## 13 · Order of implementation

The layers build on each other, and the order is chosen so every stage pays for
itself:

1. **Vocabulary and parser.** Ingredient identity plus deterministic line
   interpretation with the status model. This is the foundation — every later feature
   hangs on "what is being talked about?", and errors here poison everything
   downstream.
2. **Shopping list.** Needs only stage 1 — not a byte of BLS, not a gram. Bundling,
   variants, sections, pantry, reconciliation. Delivers half the app's value before
   the hardest problem (mapping) is even touched, and hardens parser and vocabulary
   on real recipes along the way.
3. **Measure table.** The gram bridge as its own layer, independently testable
   ("what does this line weigh?").
4. **BLS integration and nutrition view.** Import, synonym table, mapping UI,
   coverage report, subrecipe propagation. The biggest chunk, but now it lands on a
   stable identity and quantity foundation.
5. **Reconciliation passes.** BLS update reconciliation and list follow-up. Last not
   because they matter least, but because they presuppose the edges of every earlier
   layer — building them first would be papering over moving walls.

## 14 · Deliberate deviations from the brief

Three phrasings in the original brief presupposed a construction; the design
deviates knowingly:

**"Tomaten and Cocktailtomaten — one line on the shopping list."** Taken literally (a
single sum line "700 g Tomaten"), this destroys the information that 200 g of it
should be cocktail tomatoes — and exactly the wrong kind lands in the cart. The
design builds a *grouped entry* instead: one place on the list, the distinction stays
readable. If the lossy single line is truly wanted, that is a conscious decision
against variety fidelity and should be made explicitly.

**"One line per ingredient, the way people write."** Both halves together aren't
quite true: people also write "Salz und Pfeffer" or "Öl zum Braten". The design takes
the first half as the contract (one line, one ingredient) and lets compound lines
stand as what they then are — an unassignable line, visible per principle II,
splittable by the cook. Automatic splitting on "und" would be the alternative but
opens the door to wrong splits ("Süß-und-sauer-Soße").

**"How healthy a recipe is."** Energy and macronutrients answer that only very
roughly — the design deliberately delivers numbers with provenance and no verdict (no
traffic light, no score). A health verdict would be its own domain commitment with
its own attack surface; "orientation" is what is built, "healthy" promises more.
