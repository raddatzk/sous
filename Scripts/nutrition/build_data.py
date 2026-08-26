#!/usr/bin/env python3
"""Build the four bundled data files from the BLS workbook and the curation.

Replaces `merge_states.py`, whose name said what it did: it merged BLS rows by
name and threw the SBLS code away. This one does the opposite - the code is the
key, every surviving BLS row keeps its own values, and the name-grouping logic
becomes a *mapping* from kitchen word to codes.

Outputs (SousKit/Sources/SousKit/Resources/):

  - `bls.json`       one row per BLS entry: SBLS code, catalog name, food
                     group, the 16 nutrient fields. No averaging.
  - `synonyms.json`  kitchen word -> SBLS codes, weighted, plus the aliases
                     and category that used to live in `ingredients.json`.
  - `measures.json`  the gram bridge, copied verbatim from the curation.
  - `aisles.json`    BLS food group -> IngredientCategory default.

Inputs, all in this directory and all hand-curated except the workbook:

  - the xlsx (not in the repo, see README)
  - `group_codes.json`  which BLS letters are in scope and what they are
  - `kitchen_words.json` the curated kitchen words, aliases, categories, and
                        the variety relation - the words people cook with,
                        which the BLS does not have
  - `curation.json`     kitchen word -> SBLS codes where a name match cannot
                        find them (the handwork a re-run used to destroy)
  - `measures.json`     the measure table

Usage:
    python3 build_data.py <path-to-BLS_4_0_Daten_2025_DE.xlsx> [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import extract_bls
from state_suffix import split_state_suffix

REPO_ROOT = Path(__file__).resolve().parents[2]
RESOURCES = REPO_ROOT / "SousKit/Sources/SousKit/Resources"
HERE = Path(__file__).parent

# Written into bls.json so the shipped data says which release it is and what
# CC BY 4.0 asks it to say - rather than a Swift constant claiming it.
DATASET_VERSION = "BLS 4.0"
DATASET_RELEASE = "2025"
LICENSE = "CC BY 4.0"
ATTRIBUTION = "Bundeslebensmittelschlüssel (BLS) 4.0, Max Rubner-Institut"
CHANGE_NOTE = (
    "Für sous aufbereitet: auf küchenrelevante Lebensmittelgruppen gefiltert, "
    "auf 16 Nährstofffelder je 100 g gekürzt und um eine kuratierte Synonym- "
    "und Maßtabelle ergänzt. Die Nährwerte selbst sind unverändert."
)

# What a target is worth when the picker (phase 4) orders candidates, and which
# one the app computes with today: highest weight per state wins, ties go to
# the first listed.
WEIGHT_EXACT = 1.0        # the kitchen word IS the BLS name
WEIGHT_ALIAS = 0.9        # one of its aliases is - minus its position, see below
WEIGHT_CURATED = 1.0      # first code the curation names for this word and state
WEIGHT_CURATED_ALT = 0.8  # the further codes it names - real alternatives
WEIGHT_PREFIX = 0.3       # found by name prefix; a candidate, never a basis
WEIGHT_ALT = 0.8          # a further row for a state whose basis is already set

# BLS lists a food cooked five ways, and the app computes with one of them. The
# plainest reading of "cooked" wins - "gekocht" before "gebraten ohne Fett
# (Pfanne)" - rather than whichever code sorts first, which is what decided it
# while the values were being averaged and nobody had to choose.
DONENESS_PREFERENCE = [
    "gekocht", "gegart", "gedünstet", "gedämpft", "pochiert",
    "gebraten", "gebacken", "gegrillt", "frittiert", "roh",
]


def doneness_rank(name: str) -> tuple[int, int]:
    lowered = name.lower()
    for index, word in enumerate(DONENESS_PREFERENCE):
        if word in lowered:
            return (index, len(lowered))
    return (len(DONENESS_PREFERENCE), len(lowered))


def load(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def dump_json(data, path: Path) -> None:
    # No trailing newline, matching how the resource files have always been
    # written, so a re-run with unchanged data produces an empty diff.
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, indent=1, ensure_ascii=False))


def normalize(name: str) -> str:
    """Mirrors `IngredientCatalog.normalize` - trim and lowercase, nothing more.

    Deliberately the same poverty of normalization as the app's: if the two
    diverged, a word the pipeline thinks it has mapped would not be found at
    runtime. Where this hurts (umlauts, punctuation) it hurts on both sides.
    """
    return name.strip().lower()


def build_bls(rows: list[dict]) -> dict:
    entries = [
        {
            "code": row["blsCode"],
            "name": row["germanName"],
            "group": row["blsCode"][0],
            "category": row["category"],
            "perHundredGrams": row["nutrients"],
        }
        for row in sorted(rows, key=lambda r: r["blsCode"])
    ]
    return {
        "datasetVersion": DATASET_VERSION,
        "release": DATASET_RELEASE,
        "license": LICENSE,
        "attribution": ATTRIBUTION,
        "changeNote": CHANGE_NOTE,
        "entries": entries,
    }


def split_slash_synonyms(base: str) -> tuple[str, list[str]]:
    """`"Batate/Süßkartoffel"` -> `("Batate", ["Süßkartoffel"])`.

    BLS joins synonyms with a slash, and until this ran the whole string was
    one word - so "Topinambur" resolved to nothing at all although
    "Topinambur/Erdartischocke" sat right there in the table. 329 names were
    unreachable that way.

    Three shapes are deliberately left alone, because a slash does not always
    separate synonyms and a wrong split invents a word rather than finding
    one:

    * **anything with brackets.** `"Agavenbrand (Mezcal/Tequila)"` carries
      its slash *inside* the bracket, and `"Klippfisch 1/1 trocken"` is a
      fraction. Telling those from `"Frühlingszwiebel/Lauchzwiebel (ohne
      Laub)"` needs more than a rule.
    * **a first segment of more than one word.** `"Hammel Bug/Schulter"`
      means Hammel*schulter*, not Schulter - and `"Kalb Bug/Schulter"` proves
      it, since both would otherwise claim the same alias.
    * **a trailing qualifier**, which is *not* skipped but carried onto every
      segment: `"Apfelkompott/Apfelmark, ungesüßt"` is ungesüßt either way.

    That leaves 168 of the 328 slashed names split outright and 372 new
    spellings gained, with no two rows claiming one - the conservative half,
    and the half worth having. (13 more resolve through the absorption rule
    in build step 4; 6 refuse for good, all because the head names a
    different food.)
    """
    if "(" in base or ")" in base:
        return base, []
    segments = [segment.strip() for segment in base.split("/")]
    if len(segments) < 2 or not all(segments):
        return base, []
    if " " in segments[0]:
        return base, []
    if any(segment.endswith("-") for segment in segments):
        # "Zartbitter-/Halbbitterschokolade": the hyphen is suspended, the
        # tail of the last segment belongs to the first, and "Zartbitter-"
        # is not a word anybody writes.
        return base, []
    last = segments[-1]
    cut = last.find(", ")
    suffix = last[cut:] if cut != -1 else ""
    segments[-1] = last[:cut] if cut != -1 else last
    names = [segment + suffix for segment in segments]
    return names[0], [name for name in names[1:] if name != names[0]]


class SynonymBuilder:
    """Kitchen word -> SBLS codes.

    Three sources feed one table, in this order of authority:

    1. **the curation** (`curation.json`) - a word whose codes were written
       down by hand. This is where "Kartoffel" learns that BLS calls it
       "Kartoffel geschält", and it wins over everything else.
    2. **an exact name match** - a BLS base name that *is* a curated word or
       one of its aliases, case-sensitively, the way the old overlay matched.
       Every BLS base name with no curated owner becomes its own word.
    3. **a name prefix** - BLS names that start with a curated word followed
       by a separator ("Schmelzkäse schnittfest, mind. 45 % Fett i. Tr." for
       "Schmelzkäse"). These land in `candidates`, never in `targets`: they
       are what the phase-4 picker offers, not what the app computes with.
       Without this split a word deliberately left without values - the 28
       spices - would silently acquire some.

    Collisions are reported rather than silently resolved: the old
    `resolve_against_catalog` kept whichever row it saw first and said nothing.
    """

    def __init__(self, catalog: list[dict], curation: dict):
        self.catalog = catalog
        self.curated_words = {entry["name"]: entry for entry in catalog}
        self.curation = curation["words"]
        # Exact, case-sensitive, name-and-alias lookup - the old overlay, but
        # remembering *how* a name was reached. Two BLS names regularly land
        # on one curated word ("Pflaume" and its alias "Zwetschge"), and the
        # old pipeline kept whichever it happened to see first and said
        # nothing - which is how "Mandarine" ended up shipping Clementine's
        # values. The name itself now outranks any alias, and among aliases
        # the curated order decides, so the file a person edits is the file
        # that settles it.
        self.owner_by_name: dict[str, tuple[str, float]] = {}
        for entry in catalog:
            self.owner_by_name[entry["name"]] = (entry["name"], WEIGHT_EXACT)
            for index, alias in enumerate(entry.get("aliases", [])):
                self.owner_by_name.setdefault(
                    alias, (entry["name"], WEIGHT_ALIAS - index / 100)
                )
        self.stats = {
            "curated_words": 0,
            "curated_without_targets": [],
            "bls_words": 0,
            "curation_unknown_codes": [],
            "curation_unused_words": [],
            "overlay_conflicts": [],
            "prefix_candidates": 0,
            "slash_split_words": 0,
            "slash_split_spellings": 0,
            "slash_split_refused": [],
            "slash_split_absorbed": [],
            "unreachable_base_names": [],
        }

    def build(self, rows: list[dict], supplements: list[dict] | None = None) -> list[dict]:
        """`rows` become words; `supplements` are only allowed to be targets.

        A supplement (`community.json`) is a food the BLS does not list, and
        its name is whatever its own source calls it - "Nutritional yeast",
        in the language that source publishes in. Letting step 4 turn such a
        name into a kitchen word of its own would put a word nobody writes
        into a German catalog. So supplements are reachable by code, which is
        what `curation.json` names them by, and by nothing else: the kitchen
        word for one is curated like any other bridge across the two
        languages.
        """
        supplements = supplements or []
        codes = {row["blsCode"] for row in rows} | {row["blsCode"] for row in supplements}
        code_names = {row["blsCode"]: row["germanName"] for row in rows + supplements}

        # 1 - group every row under its base name and state, keeping the codes.
        by_base: dict[str, dict[str, list[str]]] = {}
        category_by_base: dict[str, str] = {}
        for row in rows:
            base, state = split_state_suffix(row["germanName"])
            by_base.setdefault(base, {}).setdefault(state or "unspecified", []).append(row["blsCode"])
            category_by_base.setdefault(base, row["category"])
        for states in by_base.values():
            for state, state_codes in states.items():
                state_codes.sort(key=lambda code: doneness_rank(code_names[code]))

        words: dict[str, dict] = {}

        # 2 - the curated words first, so they own their names.
        #
        # A variety ("Cocktailtomate") is an ordinary curated word carrying a
        # `parent`. It used to sit in its parent's alias list, which made it a
        # *spelling* of the parent - and a spelling is exactly what a shopping
        # list is allowed to add up. Reclassified here, in the data, rather
        # than guessed at run time: from the outside "Cocktailtomaten" and
        # "Tomaten" look the same, and only curation knows which of them names
        # a different thing on the shelf.
        for entry in self.catalog:
            name = entry["name"]
            words[name] = {
                "word": name,
                "aliases": entry.get("aliases", []),
                "category": entry["category"],
                "targets": [],
                "candidates": [],
                "origin": "curated",
            }
            if entry.get("parent"):
                words[name]["parent"] = entry["parent"]
        self.stats["curated_words"] = len(words)

        # 3 - the curation's explicit codes.
        for word, spec in self.curation.items():
            if word not in words:
                self.stats["curation_unused_words"].append(word)
                continue
            for state, wanted in spec["targets"].items():
                for index, code in enumerate(wanted):
                    if code not in codes:
                        self.stats["curation_unknown_codes"].append((word, code))
                        continue
                    words[word]["targets"].append({
                        "code": code,
                        "state": state,
                        "weight": WEIGHT_CURATED if index == 0 else WEIGHT_CURATED_ALT,
                    })

        # 4 - every BLS base name: onto its curated owner, or as its own word.
        # Highest-ranked first, so a word's basis is decided by rank and not
        # by which name happens to sort earlier.
        owned = []
        # Every spelling already spoken for, so a split can never take a name
        # out of another word's mouth. Seeded with the curated words, which
        # own their spellings outright.
        taken_spellings = set(self.owner_by_name)
        # Which word each spelling currently belongs to, so a refused split can
        # ask whether the word holding its head already means the same rows.
        word_by_spelling = {
            spelling: owner for spelling, (owner, _) in self.owner_by_name.items()
        }
        for base, states in sorted(by_base.items()):
            head, slash_aliases = split_slash_synonyms(base)
            # Ownership is still decided by the *whole* name, never by a
            # segment of it. Letting a segment claim the row looked like a
            # bonus — "Batate/Süßkartoffel" would join the curated
            # "Süßkartoffel" — and was a trap: "Kabanossi/Peperoni" then
            # handed a sausage's values to "Chili", whose alias "Peperoni" is
            # a different food entirely. A slash separates spellings, and a
            # spelling of one food can be the name of another.
            match = self.owner_by_name.get(base)
            if match is None:
                # The head is spoken for. Before building a second word beside
                # the first, ask what the holder actually means: where it
                # already carries every code this base has, the two are one
                # food under two names and the whole string is a spelling of
                # it — "Karotte/Möhre" beside the curated "Karotte" was a
                # second entry for the same row, with its own category to
                # contradict the first.
                #
                # The subset test is what keeps this from repeating the
                # Kabanossi/Peperoni mistake: "Schwein/Rind, Hackfleisch
                # gemischt" also has a taken head, and "Schwein" means
                # entirely different rows — so it stays a word of its own.
                if head != base and head in taken_spellings:
                    holder = words.get(word_by_spelling.get(head, ""))
                    if holder is not None:
                        row_codes = {code for codes in states.values() for code in codes}
                        held = {t["code"] for t in holder["targets"]}
                        if row_codes and row_codes <= held:
                            for spelling in [base] + slash_aliases:
                                if (spelling != holder["word"]
                                        and spelling not in taken_spellings):
                                    holder["aliases"].append(spelling)
                                    taken_spellings.add(spelling)
                                    word_by_spelling[spelling] = holder["word"]
                                    self.stats["slash_split_spellings"] += 1
                            self.stats["slash_split_absorbed"].append((base, holder["word"]))
                            continue

                # The full name stays a spelling of its own row: recipes and
                # stored mappings that wrote it must go on resolving.
                name = head if head not in taken_spellings else base
                aliases = [
                    spelling for spelling in ([base] if name != base else []) + slash_aliases
                    if spelling != name and spelling not in taken_spellings
                ]
                if name != base:
                    self.stats["slash_split_words"] += 1
                    self.stats["slash_split_spellings"] += len(aliases)
                elif slash_aliases:
                    self.stats["slash_split_refused"].append(base)
                words[name] = {
                    "word": name,
                    "aliases": aliases,
                    "category": category_by_base[base],
                    "targets": [
                        {
                            "code": code,
                            "state": state,
                            "weight": WEIGHT_EXACT if index == 0 else WEIGHT_ALT,
                        }
                        for state in sorted(states)
                        for index, code in enumerate(states[state])
                    ],
                    "candidates": [],
                    "origin": "bls",
                }
                taken_spellings.update([name] + aliases)
                for spelling in [name] + aliases:
                    word_by_spelling[spelling] = name
                self.stats["bls_words"] += 1
            else:
                owned.append((match[1], base, match[0], states))

        for weight, base, owner, states in sorted(owned, key=lambda o: (-o[0], o[1])):
            target = words[owner]
            for state, state_codes in sorted(states.items()):
                taken = {t["state"] for t in target["targets"]}
                if state in taken:
                    # Something already said what this word means in this
                    # state - the curation, or a better-ranked BLS name. In
                    # practice it is always the latter: all five conflicts are
                    # a word beating one of its own spellings ("Mandarine"
                    # over "Clementine"), and none of the three carries a
                    # curation entry at all. The loser is a real alternative,
                    # not a silent casualty: it is reported and kept as a
                    # candidate.
                    self.stats["overlay_conflicts"].append((owner, base, state, state_codes[0]))
                    target["candidates"].extend(state_codes)
                    continue
                for index, code in enumerate(state_codes):
                    target["targets"].append({
                        "code": code,
                        "state": state,
                        "weight": weight if index == 0 else min(weight, WEIGHT_ALT),
                    })

        # 4b - nothing may have fallen off the edge. Every base name the
        # rows produced has to be reachable by *some* spelling; a split that
        # renamed a word without leaving the old name behind would orphan
        # every recipe and every stored mapping that wrote it.
        reachable = set()
        for entry in words.values():
            reachable.add(entry["word"])
            reachable.update(entry["aliases"])
        self.stats["unreachable_base_names"] = sorted(set(by_base) - reachable)

        # 5 - prefix candidates for the curated words. Only for curated ones:
        # every BLS name is already a word of its own, and letting BLS names
        # collect each other would make "Apfel getrocknet" a candidate of
        # "Apfel getrocknet, gezuckert" and back again.
        base_names = sorted(by_base)
        for word in sorted(self.curated_words):
            entry = words[word]
            own = {t["code"] for t in entry["targets"]} | set(entry["candidates"])
            for base in base_names:
                if base == word or not base.startswith(word):
                    continue
                rest = base[len(word):]
                if not rest or rest[0] not in " ,-/":
                    continue
                for state_codes in by_base[base].values():
                    for code in state_codes:
                        if code in own:
                            continue
                        own.add(code)
                        entry["candidates"].append(code)
                        self.stats["prefix_candidates"] += 1

        for entry in words.values():
            entry["targets"].sort(key=lambda t: (t["state"], -t["weight"], t["code"]))
            entry["candidates"] = sorted(set(entry["candidates"]))

        self.stats["variants"] = sorted(
            w for w, e in words.items() if e.get("parent")
        )
        unknown_parents = sorted(
            e["parent"] for e in words.values()
            if e.get("parent") and e["parent"] not in words
        )
        self.stats["unknown_parents"] = unknown_parents
        self.stats["curated_without_targets"] = sorted(
            w for w, e in words.items() if e["origin"] == "curated" and not e["targets"]
        )
        # Keep the file readable: a name a person can find by eye.
        return [words[key] for key in sorted(words, key=normalize)]


def build_aisles(group_codes: dict) -> dict:
    """BLS food group -> the aisle a row lands in when nothing else says.

    The enum stays one thing (see README, "Group and aisle"): this file is the
    seam between the source's taxonomy and the app's, not a second taxonomy.
    """
    groups = []
    for letter in sorted(group_codes["letters"]):
        cfg = group_codes["letters"][letter]
        groups.append({
            "group": letter,
            "category": cfg.get("category"),
            "included": bool(cfg.get("include", False)) or bool(cfg.get("special_include_codes")),
            "note": cfg.get("note", ""),
        })
    return {
        "note": (
            "Default-Ladenbereich je BLS-Lebensmittelgruppe. Greift, wo eine Zeile "
            "oder ein Synonym keine eigene Kategorie mitbringt; die feinere "
            "Zuordnung je Zeile steht in bls.json."
        ),
        "groups": groups,
    }


def rows_from_supplements(resources: Path) -> list[dict]:
    """`community.json` entries in the shape the builder takes them.

    Missing file, missing entries: an empty list. The supplements are an
    addition the app works without, and a pipeline that refused to run
    because one was absent would make them a dependency they are not.
    """
    path = resources / "community.json"
    if not path.exists():
        return []
    return [
        {
            "blsCode": entry["code"],
            "germanName": entry["name"],
            "category": entry["category"],
            "nutrients": entry["perHundredGrams"],
        }
        for entry in load(path).get("entries", [])
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xlsx_path", type=Path, help="Path to BLS_4_0_Daten_2025_DE.xlsx")
    parser.add_argument("--group-codes", type=Path, default=HERE / "group_codes.json")
    parser.add_argument("--kitchen-words", type=Path, default=HERE / "kitchen_words.json")
    parser.add_argument("--curation", type=Path, default=HERE / "curation.json")
    parser.add_argument("--measures", type=Path, default=HERE / "measures.json")
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    parser.add_argument("--dry-run", action="store_true", help="Report without writing")
    args = parser.parse_args()

    group_codes = load(args.group_codes)
    catalog = load(args.kitchen_words)
    curation = load(args.curation)

    # A code the curation names is a code the cook is meant to get, whatever
    # the group filter thinks of its letter. It carries the category of the
    # word that asked for it.
    category_by_word = {entry["name"]: entry["category"] for entry in catalog}
    force_codes = {
        code: category_by_word.get(word, "other")
        for word, spec in curation["words"].items()
        for codes in spec["targets"].values()
        for code in codes
    }
    rows, extract_stats = extract_bls.extract_rows(args.xlsx_path, group_codes, force_codes)

    bls = build_bls(rows)
    builder = SynonymBuilder(catalog, curation)
    # `community.json` is hand-kept and lives in Resources, not here: it is
    # not derived from the workbook and this script never writes it. It is
    # read so that a curated target pointing into it survives a full re-run.
    synonyms = builder.build(rows, supplements=rows_from_supplements(args.resources))
    measures = load(args.measures)
    aisles = build_aisles(group_codes)

    stats = builder.stats
    print("=== extract ===")
    print(f"Source rows: {extract_stats['total_source_rows']}")
    print(f"Skipped (group filter): {extract_stats['skipped_by_group_filter']}")
    print(f"Skipped (all nutrients blank): {extract_stats['skipped_all_nutrients_blank']}")
    print(f"Forced in by the curation (past the group filter): {len(extract_stats['forced_in'])}")
    for code, name in extract_stats["forced_in"]:
        print(f"  {code} {name}")
    print(f"bls.json entries: {len(bls['entries'])}")

    print("\n=== synonyms ===")
    print(f"Words total: {len(synonyms)}")
    print(f"  curated (kitchen_words.json): {stats['curated_words']}")
    print(f"  from BLS names: {stats['bls_words']}")
    print(f"Words without any target (identity only, no nutrition): "
          f"{len(stats['curated_without_targets'])}")
    print(f"  {stats['curated_without_targets']}")
    print(f"Prefix candidates attached: {stats['prefix_candidates']}")
    print(f"Varieties (own word, parent named): {len(stats['variants'])}")
    if stats["unknown_parents"]:
        print(f"!! varieties naming a parent that is not a word: {stats['unknown_parents']}")
    print(f"Overlay conflicts (heavier claim wins, loser kept as candidate): "
          f"{len(stats['overlay_conflicts'])}")
    for owner, base, state, code in stats["overlay_conflicts"][:15]:
        print(f"  {owner}: BLS '{base}' [{state}] {code} -> candidate")
    if stats["curation_unknown_codes"]:
        print(f"!! curation names codes the filter drops: {stats['curation_unknown_codes']}")
    if stats["curation_unused_words"]:
        print(f"!! curation names words kitchen_words.json does not have: "
              f"{stats['curation_unused_words']}")

    print("\n=== measures ===")
    print(f"generic units: {len(measures['units'])}, per group: {len(measures['byGroup'])}, "
          f"per ingredient: {len(measures['byIngredient'])}, densities: {len(measures['densities'])}")
    print(f"aisles: {len(aisles['groups'])} groups")

    if args.dry_run:
        print("\n--dry-run: not writing any files.")
        return

    dump_json(bls, args.resources / "bls.json")
    dump_json({"words": synonyms}, args.resources / "synonyms.json")
    dump_json(measures, args.resources / "measures.json")
    dump_json(aisles, args.resources / "aisles.json")
    print(f"\nWrote bls.json, synonyms.json, measures.json, aisles.json to {args.resources}")


if __name__ == "__main__":
    sys.exit(main())
