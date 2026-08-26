# Nutrition data pipeline (BLS 4.0)

One-time (re-runnable) pipeline that derives sous's bundled food data from the
German Bundeslebensmittelschlüssel (BLS) 4.0, published by the
Max-Rubner-Institut under CC BY 4.0. No AI/LLM is involved and no live API is
called - everything comes from a downloaded spreadsheet plus the curation
files in this directory.

> **Version 2.** The pipeline used to merge BLS rows by name, average the
> collisions, and throw the SBLS code away. It now does the opposite: the code
> is the key, every surviving row keeps its own values, and the name-grouping
> logic became a *mapping* from kitchen word to codes. See "What changed in v2"
> at the end for the full list, including two bugs that fell out of it.

## What it produces

Four files in `SousKit/Sources/SousKit/Resources/`, all plain, pretty-printed,
human-readable JSON so that a contributor can fix one entry with a small
hand-edited PR - see "Fixing data by hand". You do **not** need to re-run any
of this to fix one entry.

| File | What it is | Written by |
| --- | --- | --- |
| `bls.json` | One row per BLS entry: SBLS code, catalog name, food group, aisle, the 16 nutrient fields per 100 g. Plus the dataset version, licence, attribution and change note. **No averaging, no merging.** | the pipeline |
| `synonyms.json` | Kitchen word → SBLS codes, weighted, with the aliases and category that used to live in `ingredients.json`. | the pipeline |
| `measures.json` | The gram bridge: generic unit weights, per-group and per-ingredient weights, densities. | copied verbatim from `measures.json` here |
| `aisles.json` | BLS food group → `IngredientCategory` default. | the pipeline, from `group_codes.json` |

`ingredients.json` and `nutrition.json` are gone. Their content lives in
`synonyms.json` (the names, spellings and categories) and `bls.json` (the
numbers); the piece weights moved to `measures.json`.

## Its inputs

Everything here is checked in except the workbook.

| Input | Hand-curated? | What it decides |
| --- | --- | --- |
| `BLS_4_0_Daten_2025_DE.xlsx` | no, downloaded | the numbers |
| `group_codes.json` | **yes** | which BLS letters are in scope, their category, the per-letter keyword overrides |
| `kitchen_words.json` | **yes** | the 259 curated kitchen words, their aliases, categories and the variety relation — the words people cook with, which the BLS does not have |
| `curation.json` | **yes** | kitchen word → SBLS codes, where a plain name match cannot find them |
| `measures.json` | **yes** | piece weights, generic unit weights, densities |
| `../../SousKit/Sources/SousKit/Resources/community.json` | **yes** | foods the BLS does not list at all — see "Foods the BLS does not have" |

**All four curated files are inputs and never outputs.** That is the whole
point of the split, and the fix for v1's worst property - see the warning
below.

## Re-running the pipeline from scratch

1. Download `https://blsdb.de/assets/uploads/BLS_4_0_2025_DE.zip` and unzip it.
   You need `BLS_4_0_Daten_2025_DE.xlsx` (the ~7,140-row main data workbook;
   `BLS_4_0_Components_DE_EN.xlsx` is just the nutrient-code legend and isn't
   read by these scripts). The xlsx stays out of the repo.
2. `pip install --user openpyxl` (only dependency).
3. From this directory:

   ```
   python3 build_data.py /path/to/BLS_4_0_Daten_2025_DE.xlsx
   ```

   Pass `--dry-run` to see the full stats report without writing anything, or
   `--kitchen-words`/`--curation`/`--measures`/`--group-codes`/`--resources` to point
   at different paths (useful for testing against a copy).

   `extract_bls.py` can also be run standalone (`python3 extract_bls.py
   /path/to/BLS_4_0_Daten_2025_DE.xlsx [--dump out.json]`) to inspect what gets
   extracted and filtered without touching any output file.

4. **Read the report.** It is not decoration. It names every collision, every
   code the curation asked for that the filter would have dropped, and every
   curated word that ended up without a target. A silent run is a run that
   found nothing worth telling you, and there is normally something.

5. `swift test --package-path SousKit` - `BundledDataTests` is a golden-file
   check over the shipped files (raw and cooked potato as separate codes, more
   than one Schmelzkäse row, olive oil's density, the piece weights, no
   dangling code, no two words colliding under normalization). It exists
   because nothing else would notice a run that mangled a megabyte of numbers.

## ⚠️ Re-running v1 used to destroy hand-work. Here is why it no longer does.

**This is the most important paragraph in this file.** In v1 the pipeline
*wrote* the files a person had hand-edited:

- `build_nutrition_json` set `unitWeightsGrams` to `{}` and
  `densityGramsPerMl` to `None` **unconditionally**, for every entry. The 18
  hand-made piece weights ("a medium onion ≈ 110 g") were wiped by any re-run.
- 120 curated names had nutrition only because somebody had searched the *full*
  unfiltered BLS by hand and pasted values in under the curated name. The
  pipeline could not re-derive a single one of them, and rewrote
  `nutrition.json` from scratch every run.
- `ingredients.json` was an input *and* an output ("strictly additive"), so the
  curated names were only safe as long as the append logic stayed correct.

Nothing warned about any of this. A well-meaning `python3 merge_states.py …`
would have silently thrown away weeks of curation.

**v2's rule: the pipeline never writes a file a human edits.** The hand-work
was recovered (by matching the shipped values back against the source rows,
which pinned 100 of the 120 exactly and the rest to a documented base row) and
moved into `curation.json` and `measures.json`, which are read-only inputs.
`kitchen_words.json` holds the curated words, recovered from git (`a225c6e`),
plus `Schmelzkäse` and minus the 28 that the BLS supplies under the same name
and category anyway (see "Why the curated words are not a pre-BLS leftover").
The 2,473 machine-derived names are not stored anywhere: they are re-derived
from BLS names on every run.

If you add a kitchen word or a piece weight, it goes in this directory, not in
`Resources/`.

## Re-running only the mapping, without the workbook

A curation change - a word gaining an alias, a variety moving out of an alias
list - touches only the mapping half, and the rows it maps onto are already in
`bls.json` exactly as the workbook left them:

```
python3 rebuild_synonyms.py          # --dry-run to see the counts first
```

It reads `bls.json` back into the shape `extract_bls` produces and runs the
*same* `SynonymBuilder`, so a later full re-run with the workbook produces the
same file. It writes only `synonyms.json`; anything that changes the rows
themselves still needs `build_data.py` and the xlsx.

## Varieties: a spelling and a kind are not the same thing

`kitchen_words.json` entries may carry `"parent"`. That word is then a *variety*
of another one - "Cocktailtomate" of "Tomate" - and reaches `synonyms.json` as
a word of its own with a `parent` field, not as a spelling in its parent's
alias list, which is where 57 of them used to sit.

The difference is not cosmetic: aliases are what the shopping list is allowed
to add up, so as long as "Cocktailtomaten" was a spelling of "Tomaten", 200 g
of cocktail tomatoes became an anonymous part of 700 g of tomatoes and the
wrong thing landed in the cart. As a variety it keeps its own line, grouped
under its parent, and inherits the parent's nutrition basis at run time as long
as it has none of its own.

The rule for curating one: **a variety is a word that names a different product
on the shelf**, not another word for the same one. "Meersalz" is a variety of
"Salz"; "Speisesalz" is a spelling of it. "Räucherlachs" is a variety of
"Lachs"; "Hühnerei" is a spelling of "Ei".

Watch the parent when moving a variety out. Five words got their BLS row
*through* the alias that became a variety - "Salz" through "Meersalz",
"Sellerie" through "Knollensellerie", and likewise "Schinken", "Melone",
"Essig" - and were left without a basis. `curation.json` now names the plain
row for each, which is what the bare word meant all along. `build_data.py` and
`rebuild_synonyms.py` both print the variety count; a word dropping out of
`targets` shows up in "words without any target".

## What each script does

- **`rebuild_synonyms.py`** - `build_data.py`'s mapping half, fed from the
  shipped `bls.json` instead of the workbook. See above.
- **`extract_bls.py`** - reads the xlsx sheet `BLS_4_0_Daten_2025_DE`, locates
  each of the 16 target nutrient columns *by searching the header row* for a
  cell starting with `"<BLS CODE> "` (e.g. `"ENERCC Energie (Kilokalorien)
  [kcal/100g]"`) rather than assuming a fixed column offset - the exact offsets
  shift between BLS releases depending on which nutrients are present. For each
  row it looks up the BLS code's first letter in `group_codes.json` to decide
  include/exclude and category, applies a small keyword-override rule engine
  for the letters that mix several kinds of food under one prefix (see below),
  and extracts the 16 nutrient fields (omitting any that are blank in BLS
  rather than inventing a zero - a missing value and a true zero are different
  things).

  New in v2: `force_codes`. A code named by `curation.json` is included even
  when its group is excluded wholesale. This is how `Brot`, `Brötchen`,
  `Baguette`, `Toast`, `Naan`, `Pita`, `Tortilla`, `Fladenbrot`, `Semmelbrösel`
  (group B), `Bier` (P), `Kaffee`, `Tee`, `Wasser` (N), `Mayonnaise` (Q) and
  `Blätterteig` (D) keep real values although their whole groups are out of
  scope. In v1 the same 14 rows existed only as hand-pasted numbers. **Naming a
  code in the curation *is* the decision to ship that row**, so there is no way
  to name one and silently not get it.

- **`state_suffix.py`** - `split_state_suffix()`, lifted out of the old
  `merge_states.py` unchanged, because what it is *for* changed while what it
  *does* did not. BLS spells the state two ways - `"Kartoffel geschält, roh"`
  (comma before the state word, earlier qualifiers preserved) and `"Stint roh"`
  / `"Grenadier gebraten ohne Fett (Pfanne)"` (bare trailing word) - and both
  go through the same function. `roh` → `raw`; `gekocht/gegart/gedünstet/
  gebraten/gebacken/gegrillt/gedämpft/pochiert/frittiert` → `cooked`;
  everything else in the vocabulary (`tiefgefroren`, `konserve`, `getrocknet`,
  `vegan`, …) and every word outside it (BLS also uses `geschmort`, which the
  brief's list never covered) does **not** split, and the row keeps its full
  name with state `unspecified` rather than being guessed into a bucket.

- **`group_codes.json`** - unchanged from v1: the data-driven rulebook for
  which letters are included, their default category, per-letter keyword
  overrides, per-code whitelists for letters excluded by default (P, S), and a
  global exclude keyword list (`instantpulver`, `fertigprodukt`,
  `trockenprodukt`, `zubereitet`, `für gebäck/torten`). Every letter's `note`
  documents the rationale; the highlights:

  - **Kept wholesale**: C/E→grains (E's egg rows are recategorized to dairy,
    see below), F→fruit, G→vegetables, M→dairy, Q→oils (with a dairy override
    for butter-based items), T→fish, U/V/W→meat.
  - **B, D, N excluded wholesale**: finished bread, finished pastries/cookies,
    and ready-to-drink beverages. The handful of genuinely useful rows now come
    back in through `curation.json`'s force-include rather than by hand.
  - **H is legumes/sprouts/soy by default, but the group also contains tree
    nuts & seeds, olives, coconut, plant milks, plant-based dairy
    alternatives, and composed meat-substitute products** - each gets its own
    keyword override to the right of the 17 app categories rather than forcing
    everything into "legumes".
  - **K is not "potato/starch products"** - full sampling showed potatoes,
    edible mushrooms, other tubers (Maniok, Batate, Topinambur, Yamswurzel),
    starches/flours, gnocchi, *and* a tail of frozen/instant potato snacks. The
    processed tail is excluded; the rest is keyword-routed to vegetables
    (potatoes, tubers, mushrooms) or grains (starches, flours, gnocchi).
  - **R is not just "Salz/Gewürze"** - it also holds condiments/sauces,
    vinegar, baking aids, plus 34 of 97 rows of prepared pastry fillings
    ("für Gebäck/Torten") that are excluded. The rest is keyword-routed to
    match how the curated catalog already categorizes the same items:
    sauces/condiments/bouillon/spreads → canned, vinegar → oils, baking aids →
    baking, fresh ginger → vegetables. Plain salt/pepper/dried herbs stay
    "spices".
  - **P (alcoholic drinks) and S (confectionery)** default to excluded (most of
    both are finished products), each with a curated per-code whitelist
    (`special_include_codes`) of the subset genuinely used as a cooking
    ingredient - wines/fortified wines/spirits for P, honey, sugars, syrups,
    cocoa, jam, marzipan, plain baking chocolate for S.
  - **X and Y are not "broths"** despite the letter description - both are
    overwhelmingly composed dishes. Excluded by default, with a name-pattern
    rule (`BROTH_NAME_RE`) force-including the 11 genuine plain stock rows
    (`Hühnerbrühe`, `Gemüsebrühe`, `Fleischbrühe (Rind)`, …) while rejecting
    things that merely *mention* a broth.
  - **E's egg rows are recategorized to `dairy`**, matching the curated `Ei`
    entry, so they overlay cleanly instead of landing under "grains" with the
    pasta.

- **`build_data.py`** - the main entry point, replacing `merge_states.py`.
  Extracts, then builds the synonym table, then writes the four files.

### How a kitchen word finds its codes

Three sources feed `synonyms.json`, in this order of authority. Every one of
them reports what it did.

1. **The curation** (`curation.json`). A word whose codes were written down by
   hand wins over everything else. This is where "Kartoffel" learns that BLS
   calls it "Kartoffel geschält", and where the README's old judgment calls
   became data instead of prose: `Reis`/`Basmatireis`/`Jasminreis`/
   `Risottoreis` all name `Reis poliert`; `Spaghetti`/`Penne`/`Fusilli`/
   `Nudeln` name generic egg-free dried pasta while `Tagliatelle` names egg
   pasta; `Rindfleisch` and `Schweinefleisch` name two representative cuts
   each; `Pilz` → Champignon, `Salat` → Kopfsalat, `Wurst` → Fleischwurst,
   `Kürbis` → Pumpkin, `Hokkaido` → Hokkaido. **These are now visible, editable
   lists of codes rather than a paragraph in a README nobody diffs.**

2. **An exact name match.** A BLS base name that *is* a curated word, or one of
   its aliases, case-sensitively - the old overlay. Every BLS base name with no
   curated owner becomes its own kitchen word, which is where the other 2,445
   entries come from.

3. **A name prefix.** BLS names that start with a curated word followed by a
   separator (` `, `,`, `-`, `/`) become **candidates**: "Schmelzkäse
   schnittfest, mind. 45 % Fett i. Tr." for "Schmelzkäse", the fat grades of
   "Joghurt", polished and unpolished "Reis". A compound word does *not* match
   ("Schmelzkäsezubereitung" is a different product, "Apfelsaft" is not an
   apple), which is why the count is conservative.

**Targets vs. candidates.** `targets` is what the app computes with; the
heaviest target per state is the basis. `candidates` is what phase 4's picker
will offer and is *never* a basis. The split is load-bearing: without it, the
28 words that deliberately carry identity without values (`Kurkuma`, `Zimt`,
`Cayennepfeffer`, `Chili`, `Dill`, `Muskatnuss`, `Natron`, `Chorizo`,
`Filoteig`, …) would silently acquire numbers from whatever row happens to
start with the same letters - and the app leans on their emptiness to report
"keine Nährwerte hinterlegt" rather than "nicht im Katalog".

**Weights** say how the mapping was found: `1.0` for the word being the BLS
name or the curation's first choice, `0.9 - position/100` for one of its
aliases (so the *curated alias order* decides, not whichever name sorts
first), `0.8` for a further row in a state whose basis is already set.

**Doneness order.** BLS lists a food cooked five ways and the app computes with
one of them. Within a state the plainest reading wins - `gekocht` before
`gebraten ohne Fett (Pfanne)` - rather than whichever code sorts first. Nobody
had to choose while the values were being averaged; now somebody does, and this
is the rule.

### Group and aisle: why the enum stays

`IngredientCategory` is one enum doing two jobs. It names what kind of food
something is (`title`: "Gemüse", "Milchprodukte & Eier") *and* it orders a
shopping list into a route through a shop (`aisleOrder`). `group_codes.json`
maps BLS letters straight onto it. Phase 3 had to decide whether `aisles.json`
splits the two concepts or leaves them fused.

**Decision: the enum stays fused; only the mapping becomes data.** Reasons:

- Splitting food group from aisle is a change to the *shopping list*, the
  catalog browser, the category manager and the stored category on every own
  ingredient. Phase 2 has just rewritten the shopping list. Doing both at once
  would put a schema change and a taxonomy change in the same release with no
  feature asking for either.
- The concept's shipped-data sketch asks for exactly one thing here -
  "Bereichs-Defaults: `gruppe` → store section" - which is a *mapping*, not a
  second taxonomy. `aisles.json` is that mapping.
- The source's own taxonomy is not lost: it is `bls.json`'s `group` field, the
  BLS letter, kept verbatim. So the two concepts *are* separated in the data
  (group in `bls.json`, aisle in `IngredientCategory`); `aisles.json` is the
  seam between them. What is not separated is the app's internal enum, and
  nothing in phase 3 needs it to be.
- Consequence to accept: an aisle re-route is still an enum change (the order
  a shop is walked in is app design, not data), but re-pointing a whole BLS
  group at a different aisle is now an edit to `aisles.json`.

Note that `bls.json` also carries a per-row `category`, the pipeline's keyword
refinement of the letter default - peanuts in the legume group still read as
nuts. `aisles.json` is the fallback for anything arriving with only a letter.

## Why the curated words are not a pre-BLS leftover

They predate the BLS import, so it is a fair question whether the BLS has made
them redundant. Measured against the shipped data, it has not:

- **159 of them exist in the BLS under no name at all.** The BLS knows
  "Kartoffel geschält", "Speisezwiebel", "Karotte/Möhre", "Reis poliert" — not
  Kartoffel, Zwiebel, Karotte, Reis.
- **236 of the 253 spellings are unknown to it**: Möhren→Karotte, Eier→Ei,
  Marille→Aprikose, Emmentaler→Bergkäse, Heidelbeeren→Blaubeere.
- Resolving 30 everyday ingredient names against a BLS-only catalog finds 5.
  Kartoffeln, Zwiebel, Mehl, Zucker, Butter, Milch, Ei, Salz, Sahne, Nudeln,
  Brot and Käse are among the 25 that do not resolve.
- The 28 identity-only words exist nowhere else. Without them, Kurkuma and Zimt
  become *unknown* ingredients, and the app's gap reason flips from "keine
  Nährwerte hinterlegt" to "nicht im Katalog" — losing the distinction the
  coverage report is built on.

The BLS is a catalog of analysed foods, not of the words people cook with.
These two things are the concept's two data worlds (§7), and bridging them is
what §3 calls "the single biggest lever for hit rate".

**28 entries were genuinely redundant and have been removed** (2026-08-26):
Ahornsirup, Ananas, Backpulver, Blumenkohl, Chinakohl, Eisbergsalat, Gnocchi,
Grünkohl, Honig, Kohlrabi, Kopfsalat, Leinsamen, Mangold, Puderzucker,
Radieschen, Rettich, Rosenkohl, Rucola, Salami, Sesamöl, Sonnenblumenöl,
Spargel, Spitzkohl, Thunfisch, Tofu, Tomatenmark, Wirsing, Zucchini. The BLS
supplies each under the same name *and* the same category, none carried an
alias, and none appears in `curation.json`. They come back as BLS-derived words
with identical targets — the table has the same 2,675 words either way. The one
difference: prefix candidates only attach to curated words, so 14 of them
(Spargel, Thunfisch, Blumenkohl, …) no longer carry a picker candidate list.
No figure changes, since candidates are never a basis, and phase 4's
normalized search over BLS names covers the case properly.

The test for this rule is simple: **if the BLS gives you the word, the
spellings and the category, the entry is dead weight. If it gives you only the
values, the entry is the bridge.**

## Known limitations / good follow-up tasks

- **Exact-match overlay only, by design.** The overlay is a plain
  case-sensitive string match: no fuzzy matching, no singular/plural folding,
  no umlaut folding. It matches `IngredientCatalog.normalize` in the app
  (trim + lowercase, nothing else) *on purpose* - if the two diverged, a word
  the pipeline thinks it mapped would not be found at run time. Where this
  hurts, it hurts on both sides. `BundledDataTests` checks that no two words
  collide under that normalization, which is the failure mode that would
  otherwise make one of them unreachable forever and silently.
- ~~**BLS often joins synonyms with a slash.**~~ **Done.**
  `split_slash_synonyms` turns `"Batate/Süßkartoffel"` into the word `Batate`
  with the spelling `Süßkartoffel`: 168 names split, 372 spellings gained, and
  329 names that resolved to nothing now resolve. Three shapes are refused,
  each because a wrong split invents a word rather than finding one - brackets
  (`"Agavenbrand (Mezcal/Tequila)"`, `"Klippfisch 1/1 trocken"`), a first
  segment of more than one word (`"Hammel Bug/Schulter"` means Hammel*schulter*,
  and `"Kalb Bug/Schulter"` proves it), and a suspended hyphen
  (`"Zartbitter-/Halbbitterschokolade"`). A trailing qualifier is *not* refused
  but carried onto every segment.

  **Ownership is still decided by the whole name, never by a segment.** Letting
  a segment claim the row looked like a bonus - `"Batate/Süßkartoffel"` joining
  the curated `Süßkartoffel` - and was a trap: `"Kabanossi/Peperoni"` then
  handed a sausage's values to `Chili`, whose alias `Peperoni` is a different
  food. A slash separates spellings, and a spelling of one food can be the name
  of another. `BundledDataTests` holds that case.

  The original slashed name stays a spelling of whatever it became, so recipes
  and stored mappings that wrote it go on resolving; the builder reports any
  base name no spelling reaches (`unreachable_base_names`), which is the failure
  this would otherwise cause silently.

  **A taken head is absorbed, not duplicated.** Where the split cannot claim
  its head because a word already holds it, the builder asks what that word
  means: if it already carries *every* code this base has, the two are one food
  under two names and the whole string becomes a spelling of it. That is how
  `"Karotte/Möhre"` stopped being a second word beside the curated `Karotte` —
  same codes, own category, and which shelf a cook got depended on how they had
  typed it. 13 of the 19 refusals resolved this way. The subset test is the
  guard: `"Schwein/Rind, Hackfleisch gemischt"` also has a taken head, but
  `Schwein` means entirely different rows, so it stays a word of its own. Six
  cases still refuse, all of them for that reason.
- **The measure table is thin and always will be.** 7 generic unit weights, 6
  per-group, 34 per-ingredient, 34 densities. Every value is an assumption and
  flagged as one; a unit with no entry becomes its own named gap reason in the
  coverage display rather than a made-up number. Adding entries is the easiest
  useful contribution there is.
- **Densities, per-group weights and "Tasse" ship but are not yet read.**
  `NutritionResolver` still uses the generic weights and per-ingredient piece
  weights only, exactly as before, so phase 3 changes no arithmetic it did not
  have to. Phase 5 switches the rest on - that is when a spoonful of oil stops
  weighing what a spoonful of water weighs.
- **A human should still eyeball `group_codes.json`'s categories**, especially
  the keyword-override letters (E, H, K, Q, R).

## Foods the BLS does not have

The BLS is a catalog of analysed foods, and some things people cook with are
not in it — nutritional yeast, for one. `SousKit/Sources/SousKit/Resources/community.json`
holds those rows. It is shipped data like `bls.json`, read by the same
`BLSCatalog` and reachable by the same code lookup, and it is the **only file
of shipped food rows a person edits directly**: no pipeline writes it and no
spreadsheet backs it.

Four rules, each with a test in `BundledSupplementTests`:

1. **Codes start with `Z` and are never reissued.** The BLS has only ever
   used B–Y — that is documented for 3.0 (handbook §3.6) and unchanged in 4.0
   — so `Z` cannot collide, now or after an update. Number them in sequence
   and let a deleted row's number lapse: a reused code would silently move a
   cook's confirmed basis onto a different food.
2. **The name is the source's name, verbatim** — `"Nutritional yeast"`, not
   `"Hefeflocken"`. It is the same rule `bls.json` follows and for the same
   reason: a translated name exists in no database, so nobody could check it
   and no update could find it again. The German word is a kitchen word and
   belongs in `kitchen_words.json`, bridged to the code by `curation.json`,
   exactly like every other word the catalog spells differently.
3. **Every row names its own source.** `bls.json` has one attribution for all
   3,983 rows; a supplements file has none, because its rows come from
   wherever the food happened to be documented. The `source` string is what
   the app prints under the ingredient as „Quelle: …", and it is the per-row
   half of what CC BY asks for. The file-level `attribution` names the bodies
   involved, for the sources screen.
4. **Only use sources whose licence allows it.** Ciqual (Anses) is published
   under the Licence Ouverte and is a good fit; a commercial nutrition site
   with no licence statement is not, however plausible its numbers look.
5. **A row nothing points at does not belong here.** Add a supplement only
   because a kitchen word needs it, and add that word in the same edit. This
   is not tidiness: `BLSCatalog.search` matches on the row's own name, so a
   row called `"Nutritional yeast"` cannot be found by anyone typing German —
   searching "Hefeflocken" in the basis picker returns nothing whatsoever.
   The kitchen word is the only way in, which is exactly the arrangement rule
   2 buys: the name stays checkable against its source, and the cook never
   has to see it. It is the same rule `measures.json` rows are held to.

This is also the reason not to bulk-import a table, however good its licence.
The 3,185 Ciqual rows would each need a German word before a cook could reach
any of them, and curating 3,185 words to close a handful of gaps is the whole
cost of the bridge for none of its benefit. Take the rows you have a gap for.

A row here is reachable as a *target* and nothing else. The builder is handed
these rows separately (`build(rows, supplements=…)`) so step 4 cannot turn
their names into kitchen words — which is what would otherwise put an English
word into a German catalog.

Missing values follow the BLS rule: leave the field out rather than writing a
zero. Ciqual marks unknowns with `–` and traces with `<`, and its own
documentation says not to read either as zero.

## Fixing data by hand

- **Wrong alias, category, or the word maps to the wrong food** → edit
  `kitchen_words.json` or `curation.json` here and re-run. These are inputs; a
  re-run preserves them by construction.
- **Wrong piece weight or density** → edit `measures.json` here. It is copied
  verbatim, so this needs no re-run at all if you also copy it to `Resources/`;
  re-running is cleaner. Two rules the app enforces with tests, so a new row
  either works or fails loudly:
  - **A unit that converts to millilitres is answered by a density, never by a
    weight row.** `ml`, `l`, `TL` (5 ml) and `EL` (15 ml) go through
    `densities`; `units` and `byGroup` are only for the units that convert to
    nothing — `Prise`, `Tasse`, `Bund`, `Zehe`, `Blatt`, `Pck.`, `Stk.`. A
    `byGroup` row naming a spoon is a second, contradicting answer, which is
    what four rows here were until phase 5 turned the densities on. If a spoon
    of one specific food really is not what its density says (an Esslöffel is
    not filled to the brim), write that as a **`byIngredient` row with that
    unit** — those beat the density, for that one unit.
  - **Every `byIngredient` and named `densities` row has to name a word the
    vocabulary knows** — the word itself or one of its spellings in
    `synonyms.json`. A row for a name nothing resolves to is curation that
    silently does nothing. If the food has no word yet, add it to
    `kitchen_words.json` (see below) rather than leaving the row dangling.
- **Wrong nutrition value** → that is a BLS value. Do not patch it here; if BLS
  is genuinely wrong, the right fix is a different `curation.json` target, or
  the cook's own values in the app.
- **Adding a food BLS does not have** → add it to `kitchen_words.json`. With no
  entry in `curation.json` it becomes a known ingredient whose nutrition gap
  has a name, like the 28 spices. If you have values for it from a source that
  allows it, add the row to `community.json` instead and point the curation at
  its code — see below.

You only need to re-run the whole pipeline to pull in a newer BLS release or to
change one of the filtering/mapping rules.

## What changed in v2

- One row per BLS entry, keyed by SBLS code. **`_average_nutrients` is gone**
  (decision O2): the nine Schmelzkäse are nine rows, and raw and cooked potato
  are two codes rather than one blended entry. The group filter stays.
- The state merge became a mapping: `"Kartoffel"` → `{raw: K110100, cooked:
  K110132}` instead of one averaged row.
- `resolve_against_catalog`'s silent first-one-wins policy is gone. Collisions
  are ranked (name beats alias, curated alias order beats code order) and
  **reported**. Two bugs it had been hiding:
  - `Mandarine` shipped **Clementine's** values (48 kcal instead of 53),
    because "Clementine" sorted before "Mandarine".
  - `Pfirsich` shipped **Nektarine's** values, for the same reason.
  Both now resolve to their own row. `Melone` moved from Honigmelone to
  Wassermelone, following the curated alias order - a deliberate consequence of
  the new rule, not a fix. (It moved back once "Wassermelone" became a variety
  of its own and `curation.json` had to say what the bare word means: the
  honeydew, which is what a recipe writing "Melone" means.)
- The dataset version, licence, attribution and change note moved into
  `bls.json`, so the file that changes on an update is the file that states its
  own version.
- The curated hand-work became inputs (`kitchen_words.json`, `curation.json`,
  `measures.json`) instead of being embedded in the outputs. See the warning
  above.
- `merge_states.py` is gone; `build_data.py` and `state_suffix.py` replace it.
