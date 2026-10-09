# Community

What the people who use Sous maintain together lives here, as YAML: the
ingredient catalog (the words people cook with, their spellings and varieties,
which nutrition rows they mean), the products, the nutrition sources, what a
piece or a can weighs, which category a food group belongs to, and the AI
providers.

**Edit the YAML here, never the resources the app bundles.** They are compiled
output, and you need not compile them: a pull request that changes `Community/`
is compiled for you, so a YAML edit in the browser is a whole change. How the
YAML becomes the app's data, how it is versioned and published:
[Scripts/data/README.md](../Scripts/data/README.md).

The data is licensed CC BY 4.0; see `LICENSE` and `NOTICE`.

## How to …

### … add a product

A product is a finished thing with a brand and a pack: "ja! Vegane Butter", not
"Butter". Add it to `products/<brand>.yaml` (a new file for a new brand) and
write the label into it as the pack reads, per 100 g:

```yaml
# Community/products/ja.yaml
- id: ja-vegane-butter
  kind: product
  name: ja! Vegane Butter
  brand: ja!
  category: dairy
  ean: ['4337256113007']              # quoted: an EAN keeps its leading zeros
  label:
    checked: '2026-10-02'             # the day you read the pack
    per: as-sold                      # or `drained`, for "pro 100 g abgetropft"
    per100g: {kcal: 727, fatG: 80, saturatedFatG: 37, carbsG: 0.5, sugarG: 0.5,
              proteinG: 0.2, saltG: 1.2}
```

Name and brand are enough to start with; the label can follow. The rules:
[Products](#products).

### … add an ingredient

One file per word, `ingredients/<id>.yaml`, named after the id. A word needs a
`category` and the nutrition rows it is calculated with (or `nutrition: without`):

```yaml
# Community/ingredients/zwiebel.yaml
- id: zwiebel
  name: Zwiebel
  aliases: [Zwiebeln, Speisezwiebel]
  category: vegetables
  measures: {Stk.: 110}
  nutrition:
    raw: [G480100]
```

The id is picked once, from the name, and never changes
([Ids](#ids-renames-merges-and-splits)). Which rows `nutrition` can name, and
how to name a row of Ciqual or USDA: [Nutrition](#nutrition).

### … add a spelling

Put it under `aliases` of the ingredient it means. If it names a different thing
on the shelf ("Räucherlachs" is not "Lachs"), it is a variety instead
([A variety and a spelling](#a-variety-and-a-spelling-are-not-the-same-thing)).
A spelling is unique across the whole catalog, products included.

### … add a variety

Nest it under `varieties` of the ingredient. It writes only what differs, a
`category` or a `nutrition` of its own:

```yaml
  varieties:
    - id: rote-zwiebel
      name: Rote Zwiebel
      aliases: [Rote Zwiebeln]
```

### … change what an ingredient is calculated with

Change its `nutrition:` to the rows that fit better: a BLS row by its code, a
row of Ciqual or USDA by `source: {id, ref}` ([Nutrition](#nutrition)). Nothing
else to do, the sources already hold every row.

### … say what a piece weighs

`measures` under the ingredient (`Stk.: 110`), or `weights.yaml` for a unit or a
whole food group ([Measures](#measures)).

### … add an AI provider

One file, `ki/<id>.yaml` ([AI providers](#ai-providers)). Its `baseURL` is where
a cook's key goes, so that is the line that gets reviewed.

### … add a source of nutrition values, or a new release of one

[Sources](#sources).

## Layout

```
Community/
  ingredients/<id>.yaml   one family per file: a root and its nested varieties,
                          named after the root's id
  products/<brand>.yaml   finished products, one file per brand, each with its label
  sources/<id>.yaml       one source of nutrition values: who publishes it, which
                          release, when it was downloaded, its licence, what was done
  sources/<id>.json       that source's rows, every one it has, keyed by its code
  ki/<id>.yaml            one AI provider: how Sous asks it directly (`api`) and where
                          a cook who copies the prompt opens a chat (`chat`)
  weights.yaml            units (Prise, Msp., Zehe, …), group weights, group densities
  categories.yaml         BLS food group → default category (the aisle)
  assumed-zeros.yaml      per nutrient, the BLS groups where a blank counts as 0
  retired.yaml            ids that left the catalog, each with a reason; by hand
  released-ids.txt        every id ever released; compile.py adds to it, nobody
                          removes from it (the CI checks that none went missing)
  schema.json             the shape all of the above is validated against
```

The two bookkeeping files sit beside the folders rather than in them, because
the compiler reads every `*.yaml` of `ingredients/` and `sources/` as an entry.
The vectors that pin how two spellings are compared are not community data;
they are a test fixture shared by the app and the compiler, in
`SousKit/Tests/SousKitTests/Fixtures/normalize-cases.json`.

**Which language where.** The structure is English — file names, keys
(`aliases`, `category`, `formerly`), comments, the ids of the categories
(`bakery`, `vegetables`). The content is German: the words people cook with,
their spellings, the units (`Stk.`, `Prise`) and the notes a cook may read.
That keeps the files readable to the tools and the schema, and the catalog in
the language it describes.

An ingredient never holds a number of its own. It names a row of a source —
the BLS by its code, any other source by `source: {id, ref}` — and the compiler
resolves every name into `nutrition.json`, the one file of values the app
ships, with exactly the rows the catalog uses. See [Nutrition](#nutrition) and
[Sources](#sources). A product is the exception: it carries the label of its
pack itself ([Products](#products)).

## AI providers

`ki/<id>.yaml` names, for one provider, what Sous needs to ask it with a cook's
own key: the API's `format` (`anthropic` or `openai`, which OpenAI, Grok and
Gemini's compatibility endpoint speak), the `baseURL` (https, with the version
path, no trailing slash, the one the provider's own `docs` page names), the
`keyPage` where a cook makes a key, and the `models` worth offering, best
first: the app recommends the first model the provider offers. A model may say
how to ask it (`effort`, `thinking: false`). To check a model before
listing it, `SousKit/Tests/SousKitTests/AIModelBench.swift` runs the tasks
against real models and scores them with the readers the app uses. A file may
hold only a `chat` (an id the app stores, a title, a link).

**The key goes to `baseURL`, so that line is the one to review.** The app keeps
the address a cook saved the key with. When the catalog names another one, it
does not follow: the cook is shown both, with the source and reason from
`moved` if there is one, asked to check them, and only then does the key go to
the new address. So a change of `baseURL` needs its old address in `moved`
(with where the provider announces it) for as long as devices may hold it.

`CODEOWNERS` asks the maintainer to review `ki/`. The compiler refuses an
address that is not https, that carries credentials, that is local or numeric,
or that two providers share.

## An ingredient

```yaml
# Community/ingredients/zwiebel.yaml
- id: zwiebel
  name: Zwiebel
  aliases:
    - Zwiebeln
    - Speisezwiebel
  category: vegetables
  measures: {Stk.: 110}
  nutrition:                     # rows of the sources, see Nutrition
    raw: [G480100]
    cooked: [G480132, G480152, G480182, G480162, G480072]
  via: BLS-Gruppe "Speisezwiebel"
  varieties:
    - id: rote-zwiebel
      name: Rote Zwiebel
      aliases:
        - Rote Zwiebeln
```

| field | required | a variety that leaves it out | notes |
|---|---|---|---|
| `id` | yes | — | a slug fixed when the word is created; never changes, never reused. See [Ids](#ids-renames-merges-and-splits) |
| `name` | yes | — | the display name |
| `aliases` | no | — | other spellings. `Knoblauchzehe: {unit: Zehe}` is a spelling that implies a unit |
| `category` | on a root | inherits the nearest ancestor's | one of `IngredientCategory`'s cases; the aisle follows from it |
| `measures` | no | inherits nothing yet | unit → grams, or `{grams, state, note}`; always an assumption, shown with ≈ |
| `density` | no | inherits nothing yet | g/ml, or `{gramsPerMl, note}`; otherwise the group's, otherwise water's |
| `nutrition` | on a root | inherits the parent's whole block | per state `raw` / `cooked` / `unspecified`, an ordered list of rows of the sources; or `without`. See [Nutrition](#nutrition) |
| `candidates` | no | — | further rows that may mean this word, for the curator; never computed with |
| `via` | no | — | why this mapping; for the curator, not the app |
| `formerly` | no | — | ids of entries this one absorbed in a merge |
| `varieties` | no | — | nested entries of the same shape |

### Names and spellings

**Every name and alias is unique across the whole catalog, products included,
after normalization.** Normalization is what the app compares by: case,
ß/ss, hyphens and repeated spaces do not count, so "Weißwein", "Weisswein",
"Hokkaido-Kürbis" and "Hokkaidokürbis" are each one spelling, and writing the
second one down is redundant. Accents do count: "Créme" is a typo, not a
spelling. `SousKit/Tests/SousKitTests/Fixtures/normalize-cases.json` holds the cases both the compiler and
SousKit are tested against.

A name or alias holds letters, digits, space and `- ' % / . ,` only: no
parentheses, no typographic quotes, no `½`. Quote a spelling with a comma in
it (`"Zwiebeln, rot"`).

### Ids, renames, merges and splits

The name is what a recipe says; the id is what a household row will hold
(pantry, store, a local answer) once rows are keyed by it. So the id is the
one thing about a word that never changes:

- **Pick it once, from the name**, when the word is created: lowercase,
  `ä ö ü ß` as `ae oe ue ss`, words joined by `-` (`rote-zwiebel`).
- **A new name keeps the id.** Rename "Möhre" to "Karotte" and the id stays
  `moehre`; nothing reads meaning into it. Keep the old name as an alias:
  recipes are text and say "Möhre", and the alias is what still finds them.
- **A merge moves the absorbed id under `formerly:`** on the entry that
  absorbs it, together with the absorbed entry's spellings:

  ```yaml
  - id: pflaume
    name: Pflaume
    aliases:
      - Pflaumen
      - Zwetschge          # the absorbed entry's name, now a spelling
    formerly: [zwetschge]
  ```

  The absorbed entry's own `formerly` moves along with it. The compiler turns
  every `formerly` into the rename map `ids.json`, and the app reads a row
  holding `zwetschge` as Pflaume. It rewrites the row only when the row is
  saved anyway: there is no mass rewrite when new data arrives, which would
  run on every device of a household on a different day.
- **A split is an addition.** "Paprika" becoming rot, gelb and grün adds three
  varieties under `paprika`; the old id stays, as the more general word, and
  what a household said about Paprika reaches the varieties through their
  parent.
- **Retire an id only when its thing leaves the catalog for good**, in
  `retired.yaml` with the reason. A row holding it then resolves to nothing,
  and says so.
- **An id is never reused**, not after a merge and not after a retirement: a
  row somewhere may still hold it, and would silently change meaning.

`released-ids.txt` is how the compiler knows. `compile.py` adds every id of
the catalog to it; nobody removes a line, and CI fails a pull request whose
list lost one. An id listed there must still be an entry's id, sit under some
`formerly`, or be retired, or the data does not compile. If you added a word
and renamed its id before it was ever merged, remove that line by hand: it
was never released.

An app that meets an id it neither knows nor has retired is looking at data
newer than its own, and leaves the row alone until its data catches up.

### A variety and a spelling are not the same thing

**A variety is a word that names a different product on the shelf**, not
another word for the same one. "Meersalz" is a variety of "Salz"; "Speisesalz"
is a spelling of it. "Räucherlachs" is a variety of "Lachs"; "Hühnerei" is a
spelling of "Ei".

The difference is not cosmetic: spellings are what the shopping list adds up.
As long as "Cocktailtomaten" was a spelling of "Tomaten", 200 g of cocktail
tomatoes became an anonymous part of 700 g of tomatoes and the wrong thing
landed in the cart. As a variety it keeps its own line, grouped under its
parent.

A variety states only what differs. It writes no `category` unless its aisle
differs, and no `nutrition` unless its values do: it then gets its parent's
whole block. Where a variety does set `nutrition`, it replaces the parent's
block entirely, state by state; the compiler warns when that drops a state the
parent has ("Räucherlachs sets its own nutrition but not cooked, raw").

Watch the parent when moving a variety out: a word that got its row *through*
the alias that became a variety is left without one, and a root without
`nutrition` does not compile.

### Nutrition

An ingredient never holds a number of its own. It names rows of the sources
(see [Sources](#sources)), and the compiler resolves each name into the one
file of values the app ships, with exactly the rows the catalog uses. Per
state, `raw`, `cooked` and `unspecified`, it lists rows, and within a state the
**first one is the basis**, the numbers the app shows; the rest are real
alternatives. Nothing is averaged.

A row of the BLS is named by its code. A row of any other source (Ciqual,
USDA FoodData Central, a nutrition label) is named by the code the app gives
it and by where it is, the source's id and its code there:

```yaml
  nutrition:
    raw: [G480100]                        # a row of the BLS: its code
    cooked:
      - code: Z-adzukibohnen-cooked       # a row of another source:
        source: {id: usda-sr-legacy, ref: '173728'}   # which one, and its code there
```

The BLS is the first source and the basis of most words, one among several:
another source gives a food a row where the BLS has none (nutritional yeast,
agave syrup, agar-agar, adzuki beans) or where another row fits the word
better. Any row of any source will do; the compiler ships what the catalog
names. The rules for a row of another source:

1. **The code is `Z-` plus the entry's id** (`Z-hefeflocken`), and
   `Z-<id>-<state>` where the entry has a row per state. The BLS only ever
   uses B–Y, so `Z` cannot collide, and a code derived from the id needs no
   next free number, so two pull requests cannot both take the same one.
   Z000001 and Z000002 were numbered before that and keep their codes. A
   code is never reissued: a deleted row's code lapses, since a reused one
   would silently move a cook's basis onto a different food.
2. **`ref` is the row's code in the source**: a Ciqual number, an FDC ID, an
   EAN. The app prints the source and the row as „Quelle: Ciqual 2020 (Anses),
   Nr. 11009 „Nutritional yeast““ — the per-row half of what CC BY asks for,
   built from the source's `cite`.
3. **The name stays the source's name**: "Nutritional yeast", not
   "Hefeflocken". A translated name exists in no database, so nobody could
   check it. The German word is the ingredient's name; the values and the
   source's name come from `sources/<id>.json`, and nothing is copied by hand.
4. `category` and `group` may follow the code, where the row's aisle or food
   group differs from the ingredient's.

`nutrition: without` is an answer too: the catalog knows the word and settles
it without values, as for spices none of the sources lists. The app then says
"bewusst ohne Nährwerte" rather than "nicht im Katalog". A root must either map
or say `without`, because a curated gap is an answer and a forgotten one is
not.

### Blanks that are zeros

The BLS leaves a nutrient blank where it has no value, and the app keeps a
blank as "not stated": a recipe whose energy rests on too many blanks for one
of the NRF nutrients gets no letter. For a food that by nature carries next to
none of a nutrient, vitamin C in flour or fibre in cheese, the blank is a zero
nobody wrote down. `assumed-zeros.yaml` names those cases:

```yaml
- nutrient: vitaminCMg
  groups: [B, C, E, H, M, Q, S, T, U, V, W]
  reason: Bread, grain, eggs, … carry next to no vitamin C.
```

A rule fills blanks only, only in BLS rows, and only in the groups it
names: a stated value never changes, and a Ciqual row or a product label keeps
its blanks. A group goes in only when everything in it is low enough that a
portion moves the score by nothing; a mixed group (fruit and vitamin E,
vegetables and vitamin C, spices) stays out. The rules ship in
`nutrition.json` (`assumedZero`), and the app applies them as it loads. A
group is reported as idle only when no row of the whole BLS has the blank.

## Sources

Every source of values is kept the same way, the BLS no differently from a
label: `sources/<id>.yaml` says what it is, `sources/<id>.json` holds its rows.

```yaml
# Community/sources/ciqual-2020.yaml
title: Ciqual 2020
publisher: Anses (…), Frankreich
url: https://ciqual.anses.fr
version: Ciqual 2020 (Anses)        # how a row is cited: „Quelle: <version>, …“
release: '2020-07-07'
retrieved: '2026-10-05'             # when the download was taken
license: Licence Ouverte 2.0        # one of the list in schema.json
licenseURL: https://www.etalab.gouv.fr/licence-ouverte-open-licence/
attribution: Table de composition nutritionnelle des aliments Ciqual 2020, Anses (Frankreich)
changeNote: Auf die 16 Nährstofffelder je 100 g gekürzt, …   # every source says what was done
cite: 'Nr. {ref} „{name}“'          # how one row is cited after the version
rowURL: https://…/{ref}             # optional: where one row can be looked up
download: https://…                 # where the tables come from (not in the repo)
archive: [https://github.com/raddatzk/sous/releases/download/sources-…/…]   # the same files, kept
extract: python3 Scripts/sources/extract.py ciqual-2020 '…xls'
```

The settings' "Datenquellen" page shows every source with the same fields, the
BLS first and then by how many rows each one gives the app. A licence has to be
one the schema lists (CC BY 4.0, CC0 1.0, Licence Ouverte 2.0, or a nutrition
declaration, which is a statement of fact): a nutrition site without a licence
statement is no source, and Open Food Facts is ODbL, whose share-alike does not
mix with CC BY — look a product up there, but do not copy rows.

**Naming a row of a source an ingredient does not use yet.** Edit the YAML:
a BLS code in `nutrition:`, or `source: {id, ref}` for any other source. Compile.
Nothing else: `sources/<id>.json` holds every row of the source already.

**A new release of a source.** Download it (the `download` line), run the
`extract` line, which rewrites `sources/<id>.json` from the download, and
update `release` and `retrieved`. Attach the downloaded files to a GitHub
release `sources-<date>` and point `archive` at them, so the extract can be
re-run when the original URL is gone (the first one is `sources-2026-10-05`). The diff is the release's changes, one row per
line. A code the new release no longer has fails the compile; remap it in the
same change.

**A new source.** Write `sources/<id>.yaml` with every field above. If it has
tables to download, teach `Scripts/sources/extract.py` its format (the column
for each of the app's 16 nutrients, what it writes for unknown and trace
values — both stay blank, never 0), and run it. A source without tables — a
page, the label of one pack that is no product — gets a `sources/<id>.json` written by hand, one row per code:

```json
{"rows": {
 "4388844280076": {"name": "Kokosmilch fettreduziert, 41 % Kokosmark",
   "note": "REWE Beste Wahl …", "per100g": {"kcal": 121.4, "fatG": 12.24}}
}}
```

Write a label as it reads, with the conversions described under [Products](#products).

What a household or a contributor writes under "Quelle" in the app is a
suggestion until a curator has made it a row of a registered source.

### Measures

```yaml
  measures:
    Stk.: 110                                  # one onion ≈ 110 g
    Dose: {grams: 240, state: cooked, note: …} # a can, drained
  density: 0.98                                # g/ml
```

Every measure is an assumption and the app shows it with ≈. `state` says which
nutrition row the weight belongs to: a can of chickpeas weighs 240 g drained,
and those grams are cooked chickpeas, not dry ones.

- **A unit that converts to millilitres is answered by a density**, not a
  weight: `ml`, `l`, `TL` and `EL` go through `density`. If a spoon of one food
  really is not what its density says, write that unit under `measures`: it
  beats the density for that unit.
- **`Dose`, `Glas`, `Stange`, `Zweig`, `Stiel` and `Handvoll` convert only
  through the ingredient's own measure**, never through a group or a global
  default: what one holds depends entirely on what is in it.
- Measures of a unit or a whole food group (a Prise, a Tasse of grains) go in
  `weights.yaml`.

## Products

A finished product (`kind: product`) stands **beside** the ingredients, in
`Community/products/<brand>.yaml` (a brand's file holds all its products), never
nested under a generic word, and inherits nothing. **Every one of its spellings
names the brand**: a generic word ("Proteinmüsli") must never lead to a product,
or every recipe's muesli would silently become one brand. A household that buys
the brand says so with a local product choice for its own word.

Its values come only from the pack, and are written in the product itself, under
`label`:

```yaml
- id: ja-vegane-butter
  kind: product
  name: ja! Vegane Butter
  brand: ja!
  category: dairy
  ean: ['4337256113007']
  label:
    checked: '2026-10-02'
    per: as-sold
    per100g: {kcal: 727, fatG: 80, saturatedFatG: 37, carbsG: 0.5, sugarG: 0.5,
              proteinG: 0.2, saltG: 1.2}
```

- **A product needs no values.** Name and brand are enough. Without a `label`,
  `like: margarine` lets it count with that generic word's values and weights,
  shown as an estimate ("Schätzung wie Margarine"); without `like` it is simply
  not computed. The label replaces the estimate when it arrives, and `like` can
  then go. `like` names a generic word, never another product.
- **`checked` and `per` are required**: the day the pack was read, and whether
  the values are `as-sold` or `drained`. The first `ean` is how the app cites the
  label, so a product with a label has one. Every EAN must carry a right check
  digit, and no two products share one.
- **Write the label as it reads.** `per100ml` instead of `per100g` for a liquid,
  which the compiler turns into grams through the product's `density` (which it
  then requires); `kj` where the pack gives no kcal (÷ 4.184); `saltG` for salt,
  stored as sodium (÷ 2.5), never salt and sodium both. Every label states its
  energy. The compiler notes every conversion.
- **Only what the label states.** Leave out what it does not: fibre is voluntary,
  vitamins rarely there. Absent is not zero, and nothing is extrapolated.
- `discontinued: 'true'` keeps the id and the values for old recipes; the app
  only stops suggesting the product.

The compiler makes the label a row of the source `labels` (code `Z-<id>`, cited
by the product's name and its EAN), so it ships and shows like any other row.
`sources/labels.json` is for the other case: an ingredient that rests on the
label of one pack, not on a product.

## What the compiler checks

Schema first (`schema.json`: known fields, categories, units and states;
numbers where numbers belong), then across files:

- names and aliases unique after normalization
- every code exists, in `sources/bls.json` or as a row of another source;
  every `source: {id, ref}` names a registered source and a row it has;
  Z codes unique
- every source in `sources/` has its `.yaml` and its `.json`, a licence from
  the list, and is named by at least one row
- ids unique; an ingredient file holds one family named after its root's id
- no released id vanishes: each is an entry's, under one `formerly`, or
  retired; an absorbed or retired id is never an entry's again
- a new inline code is derived from its entry's id
- a root has a category and maps or says `without`
- no ancestor loops
- product spellings name the brand; a label has `checked`, `per`, an EAN and an energy
- one assumed-zero rule per nutrient

It warns, without failing, where a spelling is another entry's spelling plus a
plural ending (the app's plural fallback strips `en`, `n`, `e`, `s`), where a
variety's own nutrition drops a state its parent has, and where an assumed-zero
group has no BLS row with that blank.

The loader is strict because YAML's conveniences are traps in a data set: every
scalar is read as a string (`no` stays "no", `1.10` stays "1.10", an EAN keeps
its leading zeros), a key written twice is an error, and anchors are refused.
