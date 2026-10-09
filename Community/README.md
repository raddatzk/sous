# Community

What the people who use Sous maintain together lives here, as YAML: the
ingredient catalog (the words people cook with, their spellings and varieties,
which source rows they mean), the nutrition sources, what a piece or a can
weighs, which category a food group belongs to, and the AI providers. `Scripts/data/compile.py` turns it into the JSON the app bundles
(`SousKit/Sources/SousKit/Resources/`).

**Edit the YAML here, never the resources.** They are compiled output, and CI
fails when they differ from `compile(Community/)`.

You need not compile by hand:
- **A pull request** that changes `Community/` is compiled by
  `.github/workflows/compile-data.yml`: where the resources differ, it commits
  them to the branch as "Compile Community/" and runs CI on that commit. A YAML edit
  in the browser is a whole change. (Branches of this repository only; a fork
  compiles itself.)
- **Locally**, `Scripts/hooks/pre-commit` compiles when a commit stages a change
  under `Community/`, and stages the resources with it. It steps aside while `Community/`
  holds unstaged changes, and never blocks a commit. Once per clone:

```
python3 -m venv Scripts/data/.venv                         # the hook prefers this one
Scripts/data/.venv/bin/pip install -r Scripts/data/requirements.txt
git config core.hooksPath Scripts/hooks
```

By hand, where you want to see the result first:

```
python3 -m pip install -r Scripts/data/requirements.txt   # once: PyYAML, jsonschema
python3 Scripts/data/compile.py                            # writes the resources
python3 Scripts/data/compile.py --check                    # what CI runs
cd SousKit && swift test                                   # BundledDataTests, the scorecard
```

The data is licensed CC BY 4.0; see `LICENSE` and `NOTICE`.

## Layout

```
Community/
  ingredients/<id>.yaml   one family per file: a root and its nested varieties,
                          named after the root's id
  products/<brand>.yaml   finished products, one file per brand (none yet)
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
ships, with exactly the rows the catalog uses. See "Sources" below.

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

## The data set and its version

The compiled files are one **data set**, and
`compile.py` writes its `manifest.json` last: the format (`schema`), the
release (`dataVersion`), and the SHA-256 of every file. The app reads a set
only through its manifest, the one it ships and the ones it fetches.

`dataVersion` is `YYYYMMDDnn`: the UTC day the compiler first saw this content,
and a counter within the day. Nobody sets it. `compile.py` raises it whenever
any file's bytes change and leaves it alone otherwise, so compile again after
extracting a new release of a source too. Bundled and published data are one series, so an app
update with newer data always wins over an older fetched set.

Two data pull requests open at once both raise the version; their manifests
conflict, and the second one compiles again on top of the first.
`--check --since <base>` fails when the data changed and the version did not
grow.

## Shared adjustments

Households share their local answers from the app ("Anpassungen teilen"). A
nightly workflow in a private inbox repository files them as issues, one per
name, with the reports as a `json sous-catalog` block (`Scripts/data/inbox.py`).
Labelling an issue there approves it — `als-alias`, `als-sorte`, or
`neues-wort` with a `kat:<Kategorie>` — and `Scripts/data/approve.py` turns it
into a pull request here that edits `Community/`, compiled. Only these mechanical
cases are written; values, weights and products stay with the curator. The
issue closes once the pull request is merged. The workflows for the inbox
repository are kept here as `Scripts/data/inbox-workflow.yml` and
`Scripts/data/inbox-approve-workflow.yml`.

## Publishing

After a merge to `main` that touches the data, the Action *Publish data*
(`.github/workflows/publish-data.yml`) runs `compile.py --check` and
`Scripts/data/publish.py`, which puts exactly the bundled files into the app's
CloudKit container, public database:

- a `DataRelease` record `release-<dataVersion>`, one asset per file in a
  field named after it (`kitchen_words.json` → `kitchen_words`), plus the
  manifest. Every asset is read back and checked against the manifest.
- only then the pointer `current-v<schema>` (type `CurrentRelease`), which
  carries the version and the manifest. Apps read it at most every 20 hours,
  by id, fetch only the files whose hash changed, and use the new set from
  their next cold start.

A push publishes to **development**, which debug builds read, and once that
succeeded to **production**: the merge is the review, and what is merged for
the catalog goes out. `publish.py` holds the resources against `Community/` itself
first, since a direct push publishes too. *Run workflow* publishes to one
environment by hand — a retry, or `--point-to`. Each environment keeps its
own server-to-server key as the secrets `CLOUDKIT_KEY_ID` and
`CLOUDKIT_PRIVATE_KEY`.

**Who may write.** Both record types grant read to everyone (no iCloud
account needed) and create and write only to the role `Publisher`, which
only the publisher's user record holds — the record the key acts as. The app
also takes a pointer or release only from that user (`CloudKitReleaseSource`)
and only of the right type: record names are unique across all types of the
zone, so a name taken first with any type that signed-in users may create
would otherwise pass. That is why no other type in the public database may
let signed-in users create records either — except `CatalogSubmission`, the
shared adjustments, which signed-in users create and only `Publisher` reads.
Core Data's types get a create grant by default whenever their schema is
initialized in development, so **check the roles before every production
deploy of the schema**:

```sh
xcrun cktool export-schema --team-id MDQY93XVHF --container-id iCloud.me.raddatz.sous \
  --environment development | grep -c 'GRANT CREATE TO "_icloud"'   # wants 1: CatalogSubmission
```

**Releases are never deleted.** `publish.py --point-to <dataVersion>` turns
the pointer to an older release, which stops devices that have not fetched
the newer one yet; a device that has keeps it, since a client never goes
back. The real undo is a revert in `Community/`, which compiles to a new, higher
version.

To publish by hand, with the key of the environment in
`CLOUDKIT_KEY_ID` and `CLOUDKIT_PRIVATE_KEY_FILE`:

```sh
python3 Scripts/data/publish.py --environment development --commit "$(git rev-parse HEAD)"
```

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

### Nutrition: a reference, not a copy

```yaml
  nutrition:
    raw: [G490100]
    cooked: [G490132, G490152, G490162, G490182]
```

Within a state the **first code is the basis**, the numbers the app shows; the
rest are real alternatives. Nothing is averaged. A code must be a row of
`sources/bls.json` or the code of a row from another source (below). Any of
the BLS's 7,140 rows will do: the compiler ships what the catalog names.

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

A rule fills blanks only, only in BLS rows, and only in the groups it
names: a stated value never changes, and a Ciqual row or a product label keeps
its blanks. A group goes in only when everything in it is low enough that a
portion moves the score by nothing; a mixed group (fruit and vitamin E,
vegetables and vitamin C, spices) stays out. The rules ship in
`nutrition.json` (`assumedZero`), and the app applies them as it loads. A
group is reported as idle only when no row of the whole BLS has the blank.

### Foods the BLS does not have

The BLS is a catalog of analysed foods, and some things people cook with are
not in it: nutritional yeast, for one. Such a food takes a row from another
source, named on the ingredient by the source's id and its code there:

```yaml
      nutrition:
        unspecified:
          - code: Z-hefeflocken          # the app's code for the row
            source: {id: ciqual-2020, ref: '11009'}
```

The name ("Nutritional yeast") and the values come from
`sources/ciqual-2020.json`; nothing is copied by hand. The rules:

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
   check it. The German word is the ingredient's name.
4. `category` and `group` may follow the code, where the row's aisle or food
   group differs from the ingredient's.

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
label, a page — gets a `sources/<id>.json` written by hand, one row per code:

```json
{"rows": {
 "4388844280076": {"name": "Kokosmilch fettreduziert, 41 % Kokosmark",
   "note": "REWE Beste Wahl …", "per100g": {"kcal": 121.4, "fatG": 12.24}}
}}
```

Write a label as it reads: `per100ml` instead of `per100g` for a liquid's label,
which the compiler turns into grams through the ingredient's `density`; `kj`
where a label gives no kcal (÷ 4.184); `saltG` for salt, stored as sodium
(÷ 2.5). The compiler notes every conversion. Missing values are left out, not
written as zero.

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

### Products

A finished product (`kind: product`) stands **beside** the ingredients, in
`Community/products/<brand>.yaml`, never nested under a generic word, and inherits
nothing. Its values come only from the label: a row of `sources/labels.json`
with `checked` (the date the label was read), `per` (`as-sold` or `drained`)
and at least its energy, named from the product by its EAN. **Every one of its spellings names the brand**: a
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
        source: {id: labels, ref: '…'}   # the EAN
```

```json
"…": {"name": "ja! Vegane Butter", "checked": "2026-10-02", "per": "as-sold",
      "per100g": {"kcal": …, "fatG": …, "saturatedFatG": …, "carbsG": …,
                  "sugarG": …, "proteinG": …, "saltG": …}}
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
- product spellings name the brand; product rows carry `checked` and `per`
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
