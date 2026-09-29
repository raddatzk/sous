# BLS pipeline: the workbook to `bls.json`

Derives `SousKit/Sources/SousKit/Resources/bls.json` from the German
Bundeslebensmittelschlüssel (BLS) 4.0, published by the Max Rubner-Institut
under CC BY 4.0. No AI is involved and no live API is called: everything comes
from a downloaded spreadsheet and `Data/`.

**This is not where the catalog is curated.** Words, spellings, varieties,
which rows they mean, weights and aisles live in `Data/` as YAML and are
compiled by `Scripts/data/compile.py`; see [`Data/README.md`](../../Data/README.md).
This pipeline is re-run only for a new BLS release or a change to the group
filter.

## What it produces

`bls.json`: one row per BLS entry, keyed by SBLS code, with the catalog name,
the food group (the code's first letter), an aisle category and the 16
nutrient fields per 100 g, plus the dataset version, licence, attribution and
change note. **No averaging, no merging**: nine Schmelzkäse are nine rows, and
raw and cooked potato are two codes. A nutrient the BLS leaves blank is left
out rather than written as zero; a missing value and a true zero are different
things.

## Its inputs

| Input | What it decides |
| --- | --- |
| `BLS_4_0_Daten_2025_DE.xlsx` | the numbers; downloaded, not in the repo |
| `Data/aisles.yaml` | which BLS letters are in scope, their category, the per-letter keyword overrides |
| `Data/ingredients/` | every code an ingredient names is kept, even where the group filter would drop it |

## Re-running it

1. Download `https://blsdb.de/assets/uploads/BLS_4_0_2025_DE.zip` and unzip
   it. You need `BLS_4_0_Daten_2025_DE.xlsx` (the ~7,140-row main data
   workbook; `BLS_4_0_Components_DE_EN.xlsx` is the nutrient-code legend and is
   not read). The xlsx stays out of the repo.
2. `python3 -m pip install openpyxl -r Scripts/data/requirements.txt`
3. From this directory:

   ```
   python3 build_data.py /path/to/BLS_4_0_Daten_2025_DE.xlsx
   ```

   `--dry-run` reports without writing. `extract_bls.py` also runs standalone
   (`python3 extract_bls.py /path/to/…xlsx [--dump out.json]`) to inspect what
   gets extracted and filtered.
4. `python3 ../data/compile.py --check` fails if an ingredient names a code
   the new release no longer has. Remap it in `Data/` in the same change.
5. `cd ../../SousKit && swift test`. `BundledDataTests` is a golden-file check
   over the shipped data: raw and cooked potato as separate codes, more than one
   Schmelzkäse row, olive oil's density, the piece weights, no dangling code.
   It exists because nothing else would notice a run that mangled a megabyte of
   numbers.

## What each script does

- **`extract_bls.py`** reads the sheet `BLS_4_0_Daten_2025_DE` and locates each
  of the 16 nutrient columns *by searching the header row* for a cell starting
  with `"<BLS CODE> "` (e.g. `"ENERCC Energie (Kilokalorien) [kcal/100g]"`)
  rather than assuming a fixed offset, since the offsets shift between
  releases. For each row it looks up the code's first letter in
  `Data/aisles.yaml` to decide include/exclude and category, and applies the
  keyword overrides for the letters that mix several kinds of food.

  **Forced codes.** A code an ingredient in `Data/` names is included even
  when its group is excluded wholesale. That is how `Brot`, `Baguette`,
  `Naan`, `Semmelbrösel` (group B), `Bier` (P), `Kaffee`, `Tee`, `Wasser` (N),
  `Mayonnaise` (Q) and `Blätterteig` (D) have real values although their whole
  groups are out of scope. **Naming a code in the catalog is the decision to
  ship that row**, so there is no way to name one and silently not get it.

- **`build_data.py`** runs the extraction with the forced codes and writes
  `bls.json`.

## The group filter (`Data/aisles.yaml`)

Every letter's `note` documents its rationale. The highlights:

- **Kept wholesale:** C/E → grains (E's egg rows are recategorized to dairy),
  F → fruit, G → vegetables, M → dairy, Q → oils (with a dairy override for
  butter-based items), T → fish, U/V/W → meat.
- **B, D, N excluded wholesale:** finished bread, finished pastries and cookies,
  ready-to-drink beverages. The useful rows come back as forced codes.
- **H is legumes, sprouts and soy by default**, but also holds tree nuts and
  seeds, olives, coconut, plant milks, dairy alternatives and meat substitutes;
  each gets a keyword override to the right category.
- **K is not "potato and starch products":** it holds potatoes, mushrooms,
  other tubers, starches, gnocchi, and a tail of frozen and instant snacks. The
  processed tail is excluded; the rest is routed to vegetables or grains.
- **R is not just salt and spices:** it also holds condiments, vinegar and
  baking aids, plus 34 rows of pastry fillings ("für Gebäck/Torten") that are
  excluded.
- **P (alcoholic drinks) and S (confectionery)** are excluded by default, each
  with a per-code whitelist (`special_include_codes`) of what is used in
  cooking: wines and spirits; honey, sugars, syrups, cocoa, jam, baking
  chocolate.
- **X and Y are overwhelmingly composed dishes.** Excluded, with a name pattern
  (`BROTH_NAME_RE`) that keeps the 11 plain stock rows (`Hühnerbrühe`,
  `Gemüsebrühe`, `Fleischbrühe (Rind)`, …) and rejects dishes that merely
  mention a broth.
- A global keyword list drops instant powders, dry mixes and prepared dishes
  (`instantpulver`, `fertigprodukt`, `trockenprodukt`, `zubereitet`,
  `für gebäck/torten`).

The keyword-override letters (E, H, K, Q, R) are worth a human look after a
new release.

### Group and aisle: why the enum stays

`IngredientCategory` does two jobs: it names what kind of food something is
("Gemüse", "Milchprodukte & Eier") *and* it orders a shopping list into a route
through a shop. `aisles.yaml` maps BLS letters onto it. The two concepts are
separated in the data (the BLS letter is `bls.json`'s `group`, verbatim; the
aisle is the category), and `aisles.json` is the seam between them. The app's
enum stays fused: splitting it would change the shopping list, the catalog
browser and every stored category with no feature asking for it. Re-pointing a
whole BLS group at another aisle is an edit to `aisles.yaml`; re-ordering the
aisles is app design.

`bls.json` also carries a per-row `category`, the keyword refinement of the
letter default (peanuts in the legume group still read as nuts). `aisles.json`
is the fallback for anything arriving with only a letter.

## History

- **v1** merged BLS rows by name, averaged collisions and threw the SBLS code
  away. It also *wrote* the files a person had hand-edited, so a re-run wiped
  the piece weights and 120 hand-pasted curations.
- **v2** (2026-08) made the code the key, kept every row's own values, and
  turned the curation into read-only inputs: `kitchen_words.json`,
  `curation.json`, `measures.json`, with `community.json` beside them. Two bugs
  fell out of the ranking that replaced "first one wins": Mandarine had shipped
  Clementine's values and Pfirsich Nektarine's.
- **v3** (2026-09, phase 2 of the data plan) moved all curation into `Data/` as
  YAML, compiled by `Scripts/data/compile.py`. This pipeline kept only the
  workbook step. The name analysis that used to run here as a report
  (`SynonymBuilder`, `state_suffix.py`, slash splitting) is in git history; it
  had stopped deciding anything once every mapping was written down.
