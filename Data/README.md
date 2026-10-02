# The catalog

Everything Sous knows about ingredients that is not a number from the BLS lives
here, as YAML: the words people cook with, their spellings and varieties, which
BLS rows they mean, what a piece or a can weighs, and which aisle a food group
belongs to. `Scripts/data/compile.py` turns it into the JSON the app bundles
(`SousKit/Sources/SousKit/Resources/`).

**Edit the YAML here, never the resources.** They are compiled output, and CI
fails when they differ from `compile(Data/)`.

```
python3 -m pip install -r Scripts/data/requirements.txt   # once: PyYAML, jsonschema
python3 Scripts/data/compile.py                            # writes the resources
python3 Scripts/data/compile.py --check                    # what CI runs
cd SousKit && swift test                                   # BundledDataTests, the scorecard
```

The data is licensed CC BY 4.0; see `LICENSE` and `NOTICE`.

## Layout

```
Data/
  ingredients/<id>.yaml   one family per file: a root and its nested varieties,
                          named after the root's id
  products/<brand>.yaml   finished products, one file per brand (none yet)
  measures.yaml           units (Prise, Msp., Zehe, …), group weights, group densities
  aisles.yaml             BLS food group → default aisle, and the group filter
                          Scripts/nutrition/build_data.py applies to the workbook
  sources.yaml            what each data source says about itself
  retired.yaml            ids that left the catalog, each with a reason
  assumed-zeros.yaml      per nutrient, the BLS groups where a blank counts as 0
  released-ids.txt        every id ever released; compile.py adds to it, nobody
                          removes from it
  schema.json             the shape all of the above is validated against
```

`bls.json` is not compiled from here. It is generated from the BLS workbook by
`Scripts/nutrition/build_data.py` (see its README) and nobody edits it; this
catalog refers to its rows by code.

## The data set and its version

The compiled files, `bls.json` included, are one **data set**, and
`compile.py` writes its `manifest.json` last: the format (`schema`), the
release (`dataVersion`), and the SHA-256 of every file. The app reads a set
only through its manifest, the one it ships and, from phase 9, the ones it
fetches.

`dataVersion` is `YYYYMMDDnn`: the UTC day the compiler first saw this content,
and a counter within the day. Nobody sets it. `compile.py` raises it whenever
any file's bytes change and leaves it alone otherwise, so compile again after
`build_data.py` too. Bundled and published data are one series, so an app
update with newer data always wins over an older fetched set.

Two data pull requests open at once both raise the version; their manifests
conflict, and the second one compiles again on top of the first.
`--check --since <base>` fails when the data changed and the version did not
grow.

## An ingredient

```yaml
# Data/ingredients/zwiebel.yaml
- id: zwiebel
  name: Zwiebel
  aliases:
    - Zwiebeln
    - Speisezwiebel
  category: vegetables
  measures: {Stk.: 110}
  nutrition:
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
| `nutrition` | on a root | inherits the parent's whole block | per state `raw` / `cooked` / `unspecified`, an ordered list of codes; or `without` |
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
spelling. `Data/normalize-cases.json` holds the cases both the compiler and
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

### Nutrition: a reference, not a copy

```yaml
  nutrition:
    raw: [G490100]
    cooked: [G490132, G490152, G490162, G490182]
```

Within a state the **first code is the basis**, the numbers the app shows; the
rest are real alternatives. Nothing is averaged. A code must exist in
`bls.json` or be written inline (below).

`nutrition: without` is an answer too: the catalog knows the word and settles
it without values, as for spices the BLS does not list. The app then says
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

A rule fills blanks only, only in `bls.json` rows, and only in the groups it
names: a stated value never changes, and a Ciqual row or a product label keeps
its blanks. A group goes in only when everything in it is low enough that a
portion moves the score by nothing; a mixed group (fruit and vitamin E,
vegetables and vitamin C, spices) stays out. The rules ship in
`community.json` (`assumedZero`), and the app applies them as it loads.

### Foods the BLS does not have

The BLS is a catalog of analysed foods, and some things people cook with are
not in it: nutritional yeast, for one. Such a row is written **inline**, on the
ingredient that needs it, with its source:

```yaml
      nutrition:
        unspecified:
          - code: Z000002                  # a new row would be Z-kokosmilch-fettarm
            name: Kokosmilch fettreduziert, 41 % Kokosmark
            category: fruit            # only where it differs from the ingredient's
            source: Nährwertdeklaration REWE Beste Wahl …, EAN 4388844280076 …
            per100g: {kcal: 121.4, fatG: 12.24, …}
```

It compiles into `community.json`. The rules:

1. **The code is `Z-` plus the entry's id** (`Z-hefeflocken`), and
   `Z-<id>-<state>` where the entry has a row per state. The BLS only ever
   uses B–Y, so `Z` cannot collide, and a code derived from the id needs no
   next free number, so two pull requests cannot both take the same one.
   Z000001 and Z000002 were numbered before that and keep their codes. A
   code is never reissued: a deleted row's code lapses, since a reused one
   would silently move a cook's basis onto a different food.
2. **The name is the source's name, verbatim**: "Nutritional yeast", not
   "Hefeflocken". A translated name exists in no database, so nobody could
   check it. The German word is the ingredient's name.
3. **Every row names its own source.** It is what the app prints as „Quelle: …",
   and the per-row half of what CC BY asks for. `sources.yaml` names the bodies
   involved, for the sources screen.
4. **Only sources whose licence allows it.** Ciqual (Anses, Licence Ouverte) is
   a good fit; a nutrition site without a licence statement is not. Open Food
   Facts is ODbL, whose share-alike does not mix with CC BY: look a product up
   there, but do not copy rows.
5. **Missing values are left out, not written as zero.** Ciqual marks unknowns
   with `–` and traces with `<`; neither is a zero.
6. **Write the label as it reads.** `per100ml` instead of `per100g` for a
   liquid's label, with the entry's `density`, which the compiler then needs;
   `kj` where a label gives no kcal (÷ 4.184); `saltG` for salt, stored as
   sodium (÷ 2.5). The compiler notes every conversion.

Take the rows you have a gap for. A bulk import would need a German word for
each of thousands of rows before a cook could reach any of them.

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
  `measures.yaml`.

### Products

A finished product (`kind: product`) stands **beside** the ingredients, in
`Data/products/<brand>.yaml`, never nested under a generic word, and inherits
nothing. Its values come only from the label, as an inline row with `source`,
`checked` (the date the label was read) and `per` (`as-sold` or `drained`),
and at least its energy, where it has a label row. **Every one of its spellings names the brand**: a
generic word ("Proteinmüsli") must never lead to a product, or every recipe's
muesli would silently become one brand. A household that buys the brand says
so with a local product choice for its own word.

```yaml
- id: ja-vegane-butter
  kind: product
  name: ja! Vegane Butter
  brand: ja!
  category: dairy
  ean: ['…']                          # quoted: an EAN keeps its leading zeros
  nutrition:
    unspecified:
      - code: Z-ja-vegane-butter
        name: ja! Vegane Butter
        source: Nährwertdeklaration der Packung
        checked: '2026-10-02'
        per: as-sold
        per100g: {kcal: …, fatG: …, saturatedFatG: …, carbsG: …, sugarG: …,
                  proteinG: …, saltG: …}
```

- **A product needs no values.** Name and brand are enough. Without a label,
  `like: margarine` lets it count with that generic word's values and weights,
  shown as an estimate ("Schätzung wie Margarine"); without `like` it is simply
  not computed. Label values replace the estimate when they arrive, and `like`
  can then go. `like` names a generic word, never another product.
- Only what the label states. Leave out what it does not: fibre is voluntary,
  vitamins rarely there. Absent is not zero, and nothing is extrapolated.
- Every EAN must carry a right check digit, and no two products share one.
- `discontinued: 'true'` keeps the id and the values for old recipes; the app
  only stops suggesting the product.

## What the compiler checks

Schema first (`schema.json`: known fields, categories, units and states;
numbers where numbers belong), then across files:

- names and aliases unique after normalization
- every code exists, in `bls.json` or inline; inline codes unique
- ids unique; an ingredient file holds one family named after its root's id
- no released id vanishes: each is an entry's, under one `formerly`, or
  retired; an absorbed or retired id is never an entry's again
- a new inline code is derived from its entry's id
- a root has a category and maps or says `without`
- no ancestor loops
- product spellings name the brand; product rows carry `source`, `checked`, `per`
- one assumed-zero rule per nutrient

It warns, without failing, where a spelling is another entry's spelling plus a
plural ending (the app's plural fallback strips `en`, `n`, `e`, `s`), where a
variety's own nutrition drops a state its parent has, and where an assumed-zero
group has no BLS row with that blank.

The loader is strict because YAML's conveniences are traps in a data set: every
scalar is read as a string (`no` stays "no", `1.10` stays "1.10", an EAN keeps
its leading zeros), a key written twice is an error, and anchors are refused.

## Why the kitchen words are not a leftover

The BLS is a catalog of analysed foods, not of the words people cook with. It
knows "Kartoffel geschält", "Speisezwiebel", "Karotte/Möhre" and "Reis poliert",
not Kartoffel, Zwiebel, Karotte and Reis, and almost none of the spellings
(Möhren, Eier, Marille). This catalog is the bridge between the two. The test
for an entry: **if the BLS gives you the word, the spellings and the category,
the entry is dead weight; if it gives you only the values, the entry is the
bridge.**
