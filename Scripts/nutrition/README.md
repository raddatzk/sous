# Nutrition data pipeline (BLS 4.0)

One-time (re-runnable) pipeline that derives per-recipe nutrition data for sous
from the German Bundeslebensmittelschlüssel (BLS) 4.0, published by the
Max-Rubner-Institut under CC BY 4.0. No AI/LLM is involved and no live API is
called - everything comes from a downloaded spreadsheet.

It produces/updates two files that ship with the app:

- `SousKit/Sources/SousKit/Resources/ingredients.json` - the ingredient catalog
  (name, aliases, category). The pipeline only **appends** new entries; every
  hand-curated entry that existed before is preserved byte-for-byte.
- `SousKit/Sources/SousKit/Resources/nutrition.json` - per-100g nutrition data
  per canonical ingredient name, written fresh from BLS data each run.

Both files are plain, pretty-printed, human-readable JSON (2-space-equivalent
indent, matching `ingredients.json`'s existing style) specifically so that,
now that sous is open source, a contributor can fix a wrong alias, category,
or nutrition value with a small hand-edited PR - see "Fixing data by hand"
below. You do **not** need to re-run any of this to fix one entry.

## Re-running the pipeline from scratch

1. Download `https://blsdb.de/assets/uploads/BLS_4_0_2025_DE.zip` and unzip it.
   You need `BLS_4_0_Daten_2025_DE.xlsx` (the ~7,140-row main data workbook;
   `BLS_4_0_Components_DE_EN.xlsx` is just the nutrient-code legend and isn't
   read by these scripts).
2. `pip install --user openpyxl` (only dependency).
3. From this directory:

   ```
   python3 merge_states.py /path/to/BLS_4_0_Daten_2025_DE.xlsx
   ```

   This reads the xlsx, applies the group-code filtering, merges raw/cooked
   state variants, overlays against the existing `ingredients.json`, and
   overwrites both `ingredients.json` (additively) and `nutrition.json`
   (fully). Pass `--dry-run` to see the full stats report without writing
   anything, or `--ingredients`/`--nutrition`/`--group-codes` to point at
   different paths (useful for testing against a copy).

   `extract_bls.py` can also be run standalone (`python3 extract_bls.py
   /path/to/BLS_4_0_Daten_2025_DE.xlsx [--dump out.json]`) if you just want to
   inspect what gets extracted/filtered without touching any output file.

## What each script does

- **`extract_bls.py`** - reads the xlsx sheet `BLS_4_0_Daten_2025_DE`, locates
  each of the 16 target nutrient columns *by searching the header row* for a
  cell starting with `"<BLS CODE> "` (e.g. `"ENERCC Energie (Kilokalorien)
  [kcal/100g]"`) rather than assuming a fixed column offset - the exact offsets
  shift between BLS releases depending on which nutrients are present. For
  each row it looks up the BLS code's first letter in `group_codes.json` to
  decide include/exclude and category, applies a small keyword-override rule
  engine for the handful of letters that mix several kinds of food under one
  prefix (see below), and extracts the 16 nutrient fields (omitting any that
  are blank in BLS rather than inventing a zero - a missing value and a true
  zero are different things).

- **`group_codes.json`** - the data-driven rulebook for the above: which
  letters are included, their default category, per-letter keyword overrides
  (e.g. "a name containing 'Erdnuss' in group H is 'nuts', not 'legumes'"),
  optional per-code whitelists for letters that are excluded by default but
  contain a handful of genuinely useful rows (P, S), and a global exclude
  keyword list (`instantpulver`, `fertigprodukt`, `trockenprodukt`,
  `zubereitet`, `für gebäck/torten`) that filters out instant-powder/prepared
  convenience products wherever they show up. Every letter's `note` field
  documents the rationale; the highlights:

  - **Kept wholesale**: C/E→grains (E's egg rows are recategorized to dairy,
    see below), F→fruit, G→vegetables, M→dairy, Q→oils (with a dairy override
    for butter-based items), T→fish, U/V/W→meat.
  - **B, D, N excluded wholesale**: finished bread, finished pastries/cookies,
    and ready-to-drink beverages respectively - none of these read as "a base
    ingredient you cook with" (the debatable case, "2 Scheiben Toastbrot" for
    B, is called out but decided against for this v1 pass).
  - **H is legumes/sprouts/soy by default, but the group actually also
    contains tree nuts & seeds, olives, coconut, plant milks, plant-based
    dairy alternatives, and composed vegetarian/vegan meat-substitute
    products** - each gets its own keyword override to the right of the 17
    app categories (nuts, vegetables, fruit, drinks, dairy, other
    respectively) rather than forcing everything into "legumes".
  - **K is not "potato/starch products"** as the brief's example suggested -
    full sampling showed potatoes, edible mushrooms, other tubers
    (Maniok/Cassava, Batate, Topinambur, Yamswurzel), starches/flours,
    gnocchi, *and* a tail of frozen/instant processed potato snacks (Pommes
    frites, Kroketten, Rösti, Kartoffelpuffer, Kartoffelchips/-sticks,
    Kartoffeltaschen, Kartoffelkloß). The processed tail is excluded
    (ultra-processed convenience food, not a base ingredient); the rest is
    keyword-routed to vegetables (potatoes, tubers, mushrooms) or grains
    (starches, flours, gnocchi).
  - **R is not just "Salz/Gewürze"** - it also holds condiments/sauces,
    vinegar, and baking aids (leavening agents, gelatin, pectin, food acids,
    candied peel), plus a large chunk (34 of 97 rows) of prepared pastry
    fillings/glazes/buttercreams ("für Gebäck/Torten") that are excluded as
    prepared cake components. The rest is keyword-routed to match how the
    *existing* curated catalog already categorizes the same items: sauces/
    condiments/bouillon cubes/spreads → canned (matching existing `Senf`,
    `Sojasauce`, `Tomatenmark`, `Gemüsebrühe`, `Hühnerbrühe`), vinegar → oils
    (matching existing `Essig`), baking aids → baking (matching existing
    `Backpulver`/`Hefe`), fresh ginger → vegetables (matching existing
    `Ingwer`). Plain salt/pepper/dried herbs stay "spices".
  - **P (alcoholic drinks) and S (confectionery)** default to excluded (most
    of both groups are finished products: cocktails/alkopops/beer styles for
    P, chocolate bars/pralines/ice cream for S), but each has a curated
    per-BLS-code whitelist (`special_include_codes`) of the subset that *is*
    genuinely used as a cooking ingredient - wines/fortified wines/spirits/
    dessert liqueurs for P, true sweeteners/baking ingredients (honey, sugar
    in its various forms, syrups, cocoa, jam, marzipan/nougat mass, plain
    baking chocolate) for S. See `group_codes.json`'s notes on "P" and "S" for
    the exact code lists and reasoning.
  - **X and Y are not "broths"** despite the letter description - full
    sampling shows both are overwhelmingly composed dishes (soups, stews,
    gratins, pancakes, sauces, desserts). Both are excluded by default, but a
    name-pattern rule (`BROTH_NAME_RE` in `extract_bls.py`) force-includes the
    genuine plain stock/broth rows: an optional single leading qualifier word
    (e.g. "Doppelte"), a compound word ending in "brühe"/"bouillon", and an
    optional single trailing one-word parenthetical (e.g. "(Huhn)") - and
    nothing else. This keeps `Hühnerbrühe`, `Gemüsebrühe`, `Fischbrühe`,
    `Rinderkraftbrühe`, `Wildbrühe`, `Kalbsbrühe`, `Fleischbrühe (Rind)`, etc.
    (11 rows total) while correctly rejecting things like "Tomatensuppe aus
    frischen Tomaten und Gemüsebrühe" that merely *mention* a broth. Category
    for these is `canned`, matching the existing curated `Gemüsebrühe`/
    `Hühnerbrühe` entries.
  - **E's egg rows are recategorized to `dairy`** (`Hühnerei`, `Wachtelei`,
    `Gänseei`, `Entenei`, `Putenei` and their Eigelb/Eiklar/Pulver variants),
    matching the existing curated `Ei` entry (category dairy, with
    `Hühnerei`/`Hühnereier`/`Eigelb`/`Eiweiß` as aliases) so the BLS rows
    overlay cleanly onto it instead of landing under "grains" with the pasta.

- **`merge_states.py`** - the main entry point. Imports `extract_bls.py`,
  then:
  1. **State-suffix merge.** For each extracted row, detects a trailing state
     word in `germanName` against the fixed vocabulary from the brief (`roh` →
     `raw`; `gekocht/gegart/gedünstet/gebraten/gebacken/gegrillt/gedämpft/
     pochiert/frittiert` → `cooked`, collapsing every doneness variant into one
     bucket since the app only models raw/cooked/unspecified; everything else
     in the vocabulary, e.g. `tiefgefroren`/`konserve`/`abgetropft`/
     `getrocknet`/`vegan`, does **not** merge and keeps the row as its own
     canonical ingredient under its full original name). BLS spells the
     suffix two ways - `"Kartoffel geschält, roh"` (comma before the state
     word, with earlier qualifiers like "geschält" preserved as part of the
     base name) and `"Stint roh"` / `"Grenadier gebraten ohne Fett (Pfanne)"`
     (bare trailing word, no comma, possibly followed by more descriptive
     text) - both are handled by the same `split_state_suffix()` function. A
     word outside the documented vocabulary entirely (BLS also uses
     `geschmort`/braised, which the brief's list doesn't cover) is treated the
     same as "no suffix found": the row keeps its full name and state
     `"unspecified"`, rather than guessing which bucket it belongs in.
     Rows that collapse onto the *same* (base name, state) pair - e.g. a
     vegetable's `gedünstet` and `gebraten` rows both becoming its one
     `"cooked"` entry - have their nutrient values **averaged field-by-field**
     rather than picking one variant and silently discarding the other's data
     (this happened for 756 of the ~3,270 raw/cooked (base, state) pairs - see
     the pipeline's stdout report for the full list of affected ingredients).
  2. **Overlay against the existing catalog.** Each BLS canonical name is
     checked *case-sensitively* against every existing `ingredients.json`
     entry's `name` and every alias. On a match, the BLS nutrition data is
     keyed under the **existing curated name**, and no new `ingredients.json`
     entry is added. On no match, a new entry is appended:
     `{name: <BLS name with only the state suffix stripped>, aliases: [],
     category: <mapped category>}` - no aliases are hand-authored for new
     entries (an already-made product decision: the app's existing
     plural-stripping fallback covers the common case at query time).
  3. **Write outputs.** `ingredients.json` = existing 229 entries, verbatim,
     followed by the new entries appended at the end (sorted alphabetically
     among themselves) so the diff against the pre-existing file is a pure,
     clean addition. `nutrition.json` is rewritten from scratch, sorted
     alphabetically, one entry per canonical name that ended up with BLS data,
     each with `perHundredGrams.raw`/`.cooked`/`.unspecified` (whichever
     states survived the merge), and `unitWeightsGrams: {}` /
     `densityGramsPerMl: null` as intentional placeholders (see "Known
     limitations" below).

## Known limitations / good follow-up tasks for contributors

- **Exact-match overlay only, by design.** The brief was explicit about not
  over-engineering name cleanup beyond state-suffix stripping, so the overlay
  check the pipeline itself performs is a plain case-sensitive string match -
  no fuzzy matching, no singular/plural folding, no synonym resolution. This
  means a few things a human will want to tidy up by hand:
  - BLS sometimes uses a different everyday name than the curated catalog for
    the same food - e.g. BLS's `Speisezwiebel` (onion) doesn't match the
    curated `Zwiebel` entry through the plain overlay. **This specific class of
    gap was closed by hand for every one of the original 229 curated names**
    (see "Filling the gaps a plain overlay missed" below) - `nutrition.json`
    now also has a `Zwiebel` entry with `Speisezwiebel`'s data, added
    alongside the separate `Speisezwiebel` entry the overlay created (both
    exist; nothing was renamed or removed). A **newly added** catalog entry
    from a future BLS re-run does not get this manual treatment automatically
    - only the 229 names that existed when this pass was done were checked.
  - BLS often uses German biological/administrative singular names
    (`Kichererbse`, `Linse`, `Kidneybohne`) where the curated catalog uses
    everyday plurals (`Kichererbsen`, `Linsen`, `Kidneybohnen`) with no
    singular alias - also closed by hand for the 229 original names, same
    caveat as above for anything added later.
  - BLS frequently joins two synonyms with a slash in one cell (`"Weinbrand/
    Brandy"`, `"Sojasauce/Sojasoße"`, `"Speisesalz/Siedesalz/Tafelsalz"`,
    `"Alaska-Pollack/Alaska-Seelachs"`). Per the "don't over-engineer" rule
    these are kept as-is rather than split into name+aliases, so they show up
    in `ingredients.json` with a slash in the name. Splitting the first
    segment out as the `name` and the rest into `aliases` would be a
    reasonable, easy follow-up PR.
- **Piece weights are hand-made estimates, and there are only 18 of them.**
  BLS gives nutrient values per 100 g and no portion sizes at all, so a line
  like `1 Zwiebel` resolved to nothing until somebody wrote down what one
  onion weighs. `unitWeightsGrams["Stk."]` was filled in by hand for the
  common piece-counted foods - Zwiebel, Speisezwiebel, Schalotte,
  Frühlingszwiebel, Ei, Kartoffel, Karotte, Tomate, Paprika, Zucchini,
  Aubergine, Gurke, Champignon, Zitrone, Limette, Orange, Apfel, Banane -
  as average edible-portion weights, **not** as sourced data. They are
  deliberately rough: a medium onion, an M egg. Every other entry still has
  an empty `unitWeightsGrams`, and `NutritionResolver` has no generic `Stk.`
  fallback on purpose, so those lines keep resolving to nothing rather than
  to a made-up number. Adding more is a good, easy follow-up - see "Fixing
  data by hand" below.

### Filling the gaps a plain overlay missed

After the pipeline ran, 148 of the app's 229 original curated ingredient names
had no nutrition data at all, purely from name mismatches like the ones above
- including basic ones like `Zwiebel`, `Kartoffel`, `Zucker`, `Mehl`, `Milch`,
`Karotte`, `Butter`, `Reis`. These were closed by hand, searching the *full*
unfiltered BLS dataset (not just the pipeline's already-filtered subset, since
a plain version of something can exist in a BLS group that got excluded
wholesale - this is how `Brot`/`Brötchen`/`Baguette`/`Toast` got real data
despite BLS's whole bread group (B) being excluded from the general catalog
import) and adding a same-shaped `nutrition.json` entry under the curated
name. **113 of 148 were resolved this way; 35 have no defensible BLS match at
all** and were deliberately left empty rather than guessed - almost entirely
fresh herbs and spice blends BLS simply doesn't catalog (`Dill`, `Kurkuma`,
`Kreuzkümmel`, `Kardamom`, `Muskatnuss`, `Rosmarin`, `Safran`, `Thymian`,
`Garam Masala`, `Currypulver`, ...), a few flatbreads (`Naan`, `Pita`,
`Tortilla`), and a handful of others (`Chorizo`, `Natron`, `Rote Zwiebel`,
`Schwarze Bohnen`/`Weiße Bohnen` - BLS only has prepared dishes containing
these, never the plain dried bean). A recipe using one of these 35 shows
partial nutrition (everything else on the list still counts) rather than none.

Several of the 113 fixes involved a judgment call worth knowing about if a
recipe's numbers look surprising:
- `Reis`/`Basmatireis`/`Jasminreis`/`Risottoreis` all point at the same
  generic "Reis poliert" data - BLS categorizes rice only by processing
  (polished/unpolished/parboiled), never by variety.
- `Spaghetti`/`Penne`/`Fusilli`/`Nudeln` all point at generic egg-free dried
  pasta; `Tagliatelle` points at egg pasta specifically.
- `Rindfleisch`/`Schweinefleisch`/`Hähnchenschenkel`/`Paprika`/`Olive`/
  `Cheddar`/`Bergkäse`/`Frischkäse` etc. are an average across a couple of
  representative cuts/variants where BLS has no single generic entry (see
  `git log`/PR history for the exact variants averaged).
- `Pilz`/`Pilze` → Champignon, `Salat` → Kopfsalat, `Wurst` → Fleischwurst,
  `Kürbis` → Hokkaido/Pumpkin - all defensible everyday defaults, not the only
  possible reading.

None of this needs the pipeline re-run to fix further - same rule as always,
just edit the number in `nutrition.json` and open a PR.
- **`unitWeightsGrams: {}` and `densityGramsPerMl: null` are placeholders for
  every single entry** - hand-authoring "1 medium onion ≈ 110g" style unit
  weights (and ml→g densities for liquids) per ingredient was explicitly out
  of scope for this pass. This is the natural next data-curation task.
- The state-suffix vocabulary is exactly what the brief specified; BLS also
  uses a few doneness words outside that list (`geschmort`/braised being the
  most common). Rows using those words are treated as "no suffix" (kept whole,
  state `unspecified`) rather than guessed into raw/cooked - safe, but it does
  mean a few "braised X" rows sit next to a merged "X" (raw+cooked) as a
  separate, un-merged entry. Extending `COOKED_WORDS` in `merge_states.py` to
  include `geschmort` (and re-running) would fold those in.
- A human should still eyeball `group_codes.json`'s category assignments,
  especially the keyword-override letters (E, H, K, Q, R) - the overrides were
  built by sampling the full row list for each letter, but food naming is
  messy and a handful of edge cases likely still landed in an imperfect
  category.

## Fixing data by hand (no pipeline re-run needed)

Both `ingredients.json` and `nutrition.json` are plain, git-diffable JSON files
- that's the whole point of keeping this project's nutrition data
spreadsheet-sourced rather than baked into compiled code. If you spot a wrong
alias, a mis-filed category, or an incorrect nutrition value:

- **Wrong alias or category** → edit the entry directly in `ingredients.json`
  and open a PR. No need to touch `nutrition.json` unless the ingredient's
  *name* changes (nutrition.json keys off the name in ingredients.json).
- **Wrong nutrition value** → edit the relevant number under the relevant
  `raw`/`cooked`/`unspecified` block in `nutrition.json` and open a PR,
  ideally with a source (BLS's own PDF documentation, a manufacturer
  nutrition label, USDA FoodData Central, etc.) in the PR description.

You only need to re-run this whole BLS pipeline if you want to pull in a newer
BLS release or change one of the group-filtering/state-merging rules
themselves - not for a single-ingredient correction.
