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
        }

    def build(self, rows: list[dict]) -> list[dict]:
        codes = {row["blsCode"] for row in rows}
        code_names = {row["blsCode"]: row["germanName"] for row in rows}

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
        for base, states in sorted(by_base.items()):
            match = self.owner_by_name.get(base)
            if match is None:
                words[base] = {
                    "word": base,
                    "aliases": [],
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
                self.stats["bls_words"] += 1
            else:
                owned.append((match[1], base, match[0], states))

        for weight, base, owner, states in sorted(owned, key=lambda o: (-o[0], o[1])):
            target = words[owner]
            for state, state_codes in sorted(states.items()):
                taken = {t["state"] for t in target["targets"]}
                if state in taken:
                    # Something already said what this word means in this
                    # state - the curation, or a better-ranked BLS name. The
                    # loser is a real alternative, not a silent casualty: it
                    # is reported and kept as a candidate.
                    self.stats["overlay_conflicts"].append((owner, base, state, state_codes[0]))
                    target["candidates"].extend(state_codes)
                    continue
                for index, code in enumerate(state_codes):
                    target["targets"].append({
                        "code": code,
                        "state": state,
                        "weight": weight if index == 0 else min(weight, WEIGHT_ALT),
                    })

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
    synonyms = builder.build(rows)
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
    print(f"Overlay conflicts (curation wins, BLS row kept as candidate): "
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
