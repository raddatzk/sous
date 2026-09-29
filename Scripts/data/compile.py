#!/usr/bin/env python3
"""Compile `Data/` into the resources SousKit bundles.

`Data/` is the one source of truth for the catalog. Everything this script
writes into `SousKit/Sources/SousKit/Resources/` is output and never edited by
hand; CI runs `compile.py --check` and fails when the two disagree.

Reads:

  - `Data/ingredients/*.yaml`  one family per file, varieties nested
  - `Data/products/*.yaml`     finished products, one brand per file
  - `Data/measures.yaml`       units, group weights, group densities
  - `Data/aisles.yaml`         BLS group -> category, and the extraction filter
  - `Data/sources.yaml`        what each source says about itself
  - `Data/retired.yaml`        ids that left the catalog, each with a reason
  - `Data/released-ids.txt`    every id ever released; it only grows
  - `Data/schema.json`         the shape all of the above is validated against
  - `Resources/bls.json`       generated from the BLS workbook by
                               `Scripts/nutrition/build_data.py`; read here only
                               to check that every code exists

Writes `kitchen_words.json`, `curation.json`, `measures.json`, `aisles.json`
and `community.json`, in the shapes the app has always read, `sources.json`,
which the sources screen reads, and `ids.json`, the rename map: every id an
entry absorbed under `formerly`, pointing at the entry, and the retired ids.
It also adds the catalog's ids to `Data/released-ids.txt`, and fails when an
id listed there is gone without being renamed or retired.

The YAML loader is strict, because YAML's conveniences are traps in a data
set: every scalar is read as a string (`no` stays "no", `1.10` stays "1.10",
an EAN keeps its leading zeros), a key written twice is an error, and anchors
are refused. Numbers are converted where the schema says a field is one.

Usage:
    python3 Scripts/data/compile.py            write the resources
    python3 Scripts/data/compile.py --check    fail if the resources differ
    python3 Scripts/data/compile.py --check --since REF
                                               also fail if released-ids.txt
                                               lost an id it had at git REF

Needs PyYAML and jsonschema (`pip install -r Scripts/data/requirements.txt`).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

import jsonschema
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA = REPO_ROOT / "Data"
RESOURCES = REPO_ROOT / "SousKit/Sources/SousKit/Resources"

STATES = ("raw", "cooked", "unspecified")

# Inline rows written before phase 3 carry numbered codes. They keep them; a
# new row's code is derived from its entry's id instead, so two pull requests
# adding a row each cannot both take the next number.
NUMBERED_Z_CODES = {"Z000001", "Z000002"}

RELEASED_IDS_HEADER = """\
# Every id the catalog has ever released, one per line, sorted.
# compile.py adds new ids; nobody removes one. An id listed here stays an
# entry's id, moves under `formerly:` on the entry that absorbed it, or is
# retired in Data/retired.yaml. It is never used for anything else again.
"""

# The texts curation.json has always opened with. The app does not read them;
# they are kept word for word so the compiled file is the file it replaces.
CURATION_NOTE = (
    "Küchenwort → SBLS-Codes. Diese Datei IST die Handarbeit, die vor dieser "
    "Pipeline-Version nur als fertige Zahlen in nutrition.json lag und die ein "
    "Neulauf zerstört hätte: die 120 kuratierten Namen, für die ein reiner "
    "Namensabgleich keinen BLS-Treffer findet. Sie ist Eingabe, nicht Ausgabe — "
    "ein Neulauf liest sie und kann sie nicht überschreiben. Seit der "
    "Listentrennung ist sie vollständig: die 57 Wörter, deren Codes vorher nur "
    "aus dem Namensabgleich des Builds fielen, stehen jetzt hier. Der Build "
    "leitet keine Zuordnung mehr her."
)
CURATION_TARGET_ORDER = (
    "Innerhalb eines Zustands ist der ERSTE Code die Basis (die Zahlen, die die "
    "App zeigt); die weiteren sind Kandidaten für den Picker aus Phase 4. "
    "Gemittelt wird nichts mehr (Entscheidung O2). `candidates` sind weitere "
    "Zeilen, die dasselbe Wort meinen können: der Picker bietet sie an, "
    "gerechnet wird nie mit ihnen."
)


# --------------------------------------------------------------------------
# Normalization (R7). `IngredientCatalog.normalize` in SousKit does the same;
# `Data/normalize-cases.json` holds the vectors both are tested against.

HYPHENS = "-‐‑"


def normalize(name: str) -> str:
    """The key two spellings are compared by: NFC, case folded to lower, ß
    written as ss, hyphens dropped, and whitespace trimmed and collapsed.
    "Hokkaido-Kürbis" and "Hokkaidokürbis" are one key; "Créme" and "Crème"
    are not, since an accent is not a spelling variant."""
    s = unicodedata.normalize("NFC", name).lower().replace("ß", "ss")
    s = s.translate({ord(h): None for h in HYPHENS})
    return " ".join(s.split())


# --------------------------------------------------------------------------
# Loading

class DataError(Exception):
    pass


class StrictLoader(yaml.BaseLoader):
    """Every scalar a string, a duplicate key an error, no anchors."""

    def compose_node(self, parent, index):
        event = self.peek_event()
        if isinstance(event, yaml.AliasEvent) or getattr(event, "anchor", None):
            raise DataError(f"{self._where(event.start_mark)}: anchors and aliases are not "
                            f"allowed; write the value out")
        return super().compose_node(parent, index)

    def construct_mapping(self, node, deep=False):
        seen: dict[str, yaml.Node] = {}
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise DataError(
                    f"{self._where(key_node.start_mark)}: the key {key!r} is written twice "
                    f"(first at line {seen[key].start_mark.line + 1})"
                )
            seen[key] = key_node
        return super().construct_mapping(node, deep=deep)

    def _where(self, mark) -> str:
        return f"{relative(Path(mark.name))}:{mark.line + 1}"


def relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def nfc(value):
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value)
    if isinstance(value, list):
        return [nfc(v) for v in value]
    if isinstance(value, dict):
        return {nfc(k): nfc(v) for k, v in value.items()}
    return value


def load_yaml(path: Path):
    with open(path, encoding="utf-8") as f:
        loader = StrictLoader(f)
        loader.name = str(path)
        try:
            return nfc(loader.get_single_data())
        except yaml.YAMLError as error:
            raise DataError(f"{relative(path)}: {error}") from None
        finally:
            loader.dispose()


def number(text: str):
    """"110" -> 110, "0.3" -> 0.3. The schema has already said it is one."""
    return int(text) if re.fullmatch(r"-?\d+", text) else float(text)


def boolean(text: str) -> bool:
    return {"true": True, "false": False}[text]


# --------------------------------------------------------------------------
# The catalog, flattened

@dataclass
class Word:
    id: str
    name: str
    file: str
    aliases: list[str] = field(default_factory=list)
    alias_units: dict[str, str] = field(default_factory=dict)
    category: str | None = None
    parent: str | None = None
    kind: str | None = None
    brand: str | None = None
    density: dict | None = None
    measures: dict = field(default_factory=dict)
    nutrition: object = None          # None, "without", or state -> [code | row]
    candidates: list[str] = field(default_factory=list)
    via: str | None = None
    formerly: list[str] = field(default_factory=list)
    raw: dict = field(default_factory=dict)

    @property
    def spellings(self) -> list[str]:
        return [self.name] + self.aliases


def flatten(entry: dict, file: str, parent: Word | None, out: list[Word]) -> None:
    word = Word(id=entry["id"], name=entry["name"], file=file, raw=entry)
    for alias in entry.get("aliases", []):
        if isinstance(alias, dict):
            (spelling, spec), = alias.items()
            word.aliases.append(spelling)
            word.alias_units[spelling] = spec["unit"]
        else:
            word.aliases.append(alias)
    word.category = entry.get("category")
    word.parent = parent.name if parent else None
    word.kind = entry.get("kind")
    word.brand = entry.get("brand")
    density = entry.get("density")
    if density is not None:
        word.density = density if isinstance(density, dict) else {"gramsPerMl": density}
    for unit, spec in entry.get("measures", {}).items():
        word.measures[unit] = spec if isinstance(spec, dict) else {"grams": spec}
    word.nutrition = entry.get("nutrition")
    word.candidates = list(entry.get("candidates", []))
    word.via = entry.get("via")
    word.formerly = list(entry.get("formerly", []))
    out.append(word)
    for variety in entry.get("varieties", []):
        flatten(variety, file, word, out)


@dataclass
class Dataset:
    words: list[Word]
    measures: dict
    aisles: dict
    sources: dict
    bls_codes: set[str]
    retired: dict[str, str] = field(default_factory=dict)
    released: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def load_dataset(data: Path, resources: Path) -> Dataset:
    schema = json.loads((data / "schema.json").read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    errors: list[str] = []

    def validated(path: Path, definition: str):
        document = load_yaml(path)
        sub = validator.evolve(schema={"$ref": f"#/$defs/{definition}", "$defs": schema["$defs"]})
        for error in sorted(sub.iter_errors(document), key=lambda e: list(e.absolute_path)):
            where = "/".join(str(p) for p in error.absolute_path) or "(top)"
            errors.append(f"{relative(path)}: {where}: {error.message}")
        return document

    words: list[Word] = []
    for folder, definition in (("ingredients", "ingredientFile"), ("products", "productFile")):
        for path in sorted((data / folder).glob("*.yaml")):
            document = validated(path, definition)
            if errors:
                continue
            for entry in document:
                flatten(entry, relative(path), None, words)
            # A family per ingredient file, named after its root; a product
            # file is a brand's and holds as many products as the brand has.
            if folder == "ingredients" and len(document) != 1:
                errors.append(f"{relative(path)}: one family per file, found {len(document)} roots")
            elif folder == "ingredients" and document[0]["id"] != path.stem:
                errors.append(
                    f"{relative(path)}: the file is named {path.stem!r}, its root has the "
                    f"id {document[0]['id']!r}; name the file after the root"
                )
    measures = validated(data / "measures.yaml", "measuresFile")
    aisles = validated(data / "aisles.yaml", "aislesFile")
    sources = validated(data / "sources.yaml", "sourcesFile")
    retired = validated(data / "retired.yaml", "retiredFile") or []
    if errors:
        raise DataError("\n".join(errors))

    retired_ids: dict[str, str] = {}
    for row in retired:
        if row["id"] in retired_ids:
            errors.append(f"Data/retired.yaml: {row['id']!r} is retired twice")
        retired_ids[row["id"]] = row["reason"]
    if errors:
        raise DataError("\n".join(errors))

    bls = json.loads((resources / "bls.json").read_text(encoding="utf-8"))
    return Dataset(
        words=words, measures=measures, aisles=aisles, sources=sources,
        bls_codes={row["code"] for row in bls["entries"]},
        retired=retired_ids,
        released=read_released(data / "released-ids.txt"),
    )


def read_released(path: Path) -> list[str]:
    if not path.exists():
        return []
    return parse_released(path.read_text(encoding="utf-8"))


def parse_released(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines()
            if line.strip() and not line.startswith("#")]


# --------------------------------------------------------------------------
# Checks (INGREDIENTS-DATA §3 K)

SPELLING_PUNCTUATION = set(" -'%/.,")
PLURAL_SUFFIXES = ("en", "n", "e", "s")


def inline_rows(word: Word):
    if isinstance(word.nutrition, dict):
        for items in word.nutrition.values():
            for item in items:
                if isinstance(item, dict):
                    yield item


def codes_of(word: Word):
    if isinstance(word.nutrition, dict):
        for state, items in word.nutrition.items():
            for item in items:
                yield state, item["code"] if isinstance(item, dict) else item


def id_errors(dataset: Dataset) -> list[str]:
    """INGREDIENTS-DATA §3 F. An id is fixed when its entry is created and is
    never reused. Once released, it stays an entry's id, moves under
    `formerly:` on the entry that absorbed it, or is retired; the app resolves
    a household row written with an old id through what this leaves behind."""
    errors: list[str] = []
    by_id: dict[str, Word] = {}
    for word in dataset.words:
        if word.id in by_id:
            errors.append(f"{word.file}: the id {word.id!r} is used twice "
                          f"({by_id[word.id].name!r} and {word.name!r})")
        by_id[word.id] = word

    absorbed: dict[str, Word] = {}
    for word in dataset.words:
        for old in word.formerly:
            if old in by_id:
                errors.append(
                    f"{word.file}: {word.name} lists {old!r} under formerly, but "
                    f"{by_id[old].name} in {by_id[old].file} still has that id; an id "
                    f"is never reused"
                )
            elif old in absorbed:
                errors.append(f"{word.file}: {old!r} is listed under formerly by both "
                              f"{absorbed[old].name} and {word.name}; one entry absorbs it")
            absorbed[old] = word
    for old, reason in dataset.retired.items():
        if old in by_id:
            errors.append(f"Data/retired.yaml: {old!r} is retired, but {by_id[old].name} in "
                          f"{by_id[old].file} still has that id; an id is never reused")
        elif old in absorbed:
            errors.append(f"Data/retired.yaml: {old!r} is retired and listed under formerly "
                          f"by {absorbed[old].name}; it is one or the other")

    released = set(dataset.released)
    for old in sorted(released - set(by_id) - set(absorbed) - set(dataset.retired)):
        errors.append(
            f"Data/released-ids.txt: the id {old!r} was released and no entry has it any "
            f"more. A released id never disappears: keep it on its entry (a new name keeps "
            f"the id), list it under `formerly:` on the entry that absorbed it, or retire "
            f"it in Data/retired.yaml with a reason"
        )
    for old, word in sorted(absorbed.items()):
        if old not in released:
            errors.append(f"{word.file}: {word.name} lists {old!r} under formerly, which was "
                          f"never released; nothing can point at it, so drop it")
    for old in sorted(set(dataset.retired) - released):
        errors.append(f"Data/retired.yaml: {old!r} was never released; nothing can point "
                      f"at it, so drop it")
    return errors


def released_ids(dataset: Dataset) -> str:
    """`Data/released-ids.txt` with this catalog's ids added."""
    ids = set(dataset.released) | {word.id for word in dataset.words}
    return RELEASED_IDS_HEADER + "".join(f"{i}\n" for i in sorted(ids))


def lost_ids(before: str, after: str) -> list[str]:
    """Ids a version of `released-ids.txt` had that a later one lacks."""
    return sorted(set(parse_released(before)) - set(parse_released(after)))


def check(dataset: Dataset) -> None:
    errors: list[str] = []
    warnings = dataset.warnings
    words = dataset.words

    errors.extend(id_errors(dataset))

    # Names and aliases: once across the whole catalog, products included,
    # compared the way the app compares them.
    owner: dict[str, tuple[Word, str]] = {}
    for word in words:
        for spelling in word.spellings:
            bad = sorted({c for c in spelling if not (c.isalnum() or c in SPELLING_PUNCTUATION)})
            if bad:
                errors.append(f"{word.file}: {spelling!r} contains {''.join(bad)!r}; a name or "
                              f"alias holds letters, digits, space and - ' % / . , only")
            key = normalize(spelling)
            if key in owner:
                other, other_spelling = owner[key]
                if other is word:
                    errors.append(
                        f"{word.file}: {spelling!r} and {other_spelling!r} are the same "
                        f"spelling once normalized ({key!r}); keep one"
                    )
                else:
                    errors.append(
                        f"{word.file}: {spelling!r} ({word.name}) is already spelled "
                        f"{other_spelling!r} by {other.name} in {other.file}"
                    )
            else:
                owner[key] = (word, spelling)

    # The app's plural fallback strips en/n/e/s from a name it does not know.
    # A spelling that is another entry's spelling plus such a suffix is where
    # that fallback could start answering for the wrong food.
    for key, (word, spelling) in owner.items():
        for suffix in PLURAL_SUFFIXES:
            stem = key[: -len(suffix)]
            if key.endswith(suffix) and len(stem) >= 3 and stem in owner:
                other, other_spelling = owner[stem]
                if other is not word:
                    warnings.append(
                        f"{word.file}: {spelling!r} ({word.name}) is {other_spelling!r} "
                        f"({other.name}) plus {suffix!r}; the plural fallback may confuse them"
                    )

    # Structure: a root answers for its nutrition; nothing loops.
    by_name = {word.name: word for word in words}
    for word in words:
        if word.parent is None and word.nutrition is None:
            errors.append(f"{word.file}: {word.name} maps to no code and does not say "
                          f"`nutrition: without`; a root must do one or the other")
        if word.parent is None and word.category is None:
            errors.append(f"{word.file}: {word.name} is a root without a category")
        if word.nutrition is None and (word.candidates or word.via):
            errors.append(f"{word.file}: {word.name} has candidates or a via but no nutrition")
        seen = set()
        current = word
        while current is not None:
            if current.name in seen:
                errors.append(f"{word.file}: {word.name} is its own ancestor")
                break
            seen.add(current.name)
            current = by_name.get(current.parent) if current.parent else None

    # Codes: every one exists, in bls.json or inline; inline ones are Z codes,
    # written once, and a new one is named after its entry's id.
    inline: dict[str, Word] = {}
    for word in words:
        for row in inline_rows(word):
            code = row["code"]
            if code in inline or code in dataset.bls_codes:
                errors.append(f"{word.file}: the inline code {code} is used twice")
            inline[code] = word
            own = f"Z-{word.id}"
            if code not in NUMBERED_Z_CODES and code != own and not (
                code.startswith(own + "-") and code[len(own) + 1:] in STATES
            ):
                errors.append(f"{word.file}: {word.name}'s inline code {code} is not "
                              f"derived from its id; write {own}, or {own}-<state> where "
                              f"the entry has a row per state")
    known = dataset.bls_codes | set(inline)
    for word in words:
        for state, code in codes_of(word):
            if code not in known:
                errors.append(f"{word.file}: {word.name} [{state}] names {code}, "
                              f"which is neither in bls.json nor written inline")
        for code in word.candidates:
            if code not in known:
                errors.append(f"{word.file}: {word.name} names the candidate {code}, "
                              f"which is not in bls.json")
        if isinstance(word.nutrition, dict) and word.parent is not None:
            parent_states = by_name[word.parent].nutrition
            if isinstance(parent_states, dict) and set(parent_states) - set(word.nutrition):
                missing = sorted(set(parent_states) - set(word.nutrition))
                warnings.append(f"{word.file}: {word.name} sets its own nutrition but not "
                                f"{', '.join(missing)}, which its parent has; those states "
                                f"are not inherited")

    # Products: the brand in every writing; the label's provenance on every row.
    for word in words:
        if word.kind != "product":
            continue
        if word.parent is not None:
            errors.append(f"{word.file}: {word.name} is a product nested under {word.parent}; "
                          f"a product stands beside the ingredients")
        brand = normalize(word.brand or "")
        for spelling in word.spellings:
            if brand not in normalize(spelling):
                errors.append(f"{word.file}: the product spelling {spelling!r} does not name "
                              f"the brand {word.brand!r}; a generic word must never lead to "
                              f"a product")
        rows = list(inline_rows(word))
        if not rows:
            errors.append(f"{word.file}: the product {word.name} has no label row")
        for row in rows:
            for key in ("source", "checked", "per"):
                if key not in row:
                    errors.append(f"{word.file}: the product row {row['code']} has no {key!r}")

    if errors:
        raise DataError("\n".join(errors))


# --------------------------------------------------------------------------
# Output

def catalog_order(words: list[Word]) -> list[Word]:
    return sorted(words, key=lambda w: w.name.strip().lower())


def category_of(word: Word, by_name: dict[str, Word]) -> str:
    while word.category is None:
        word = by_name[word.parent]
    return word.category


def kitchen_words(dataset: Dataset) -> list[dict]:
    out = []
    for word in catalog_order(dataset.words):
        # `id` is new in phase 3; an app that predates it ignores the key.
        row: dict = {"id": word.id, "name": word.name, "aliases": word.aliases}
        # The spelling stays in `aliases` too, so an app that predates
        # `aliasUnits` still recognizes it; it only misses the unit.
        if word.alias_units:
            row["aliasUnits"] = word.alias_units
        if word.category is not None:
            row["category"] = word.category
        if word.parent is not None:
            row["parent"] = word.parent
        out.append(row)
    return out


def curation(dataset: Dataset) -> dict:
    words = {}
    for word in catalog_order(dataset.words):
        if word.nutrition is None:
            continue
        if word.nutrition == "without":
            entry: dict = {"withoutValues": True}
        else:
            entry = {"targets": {
                state: [item["code"] if isinstance(item, dict) else item for item in items]
                for state, items in word.nutrition.items()
            }}
        if word.via is not None:
            entry["via"] = word.via
        if word.candidates:
            entry["candidates"] = word.candidates
        words[word.name] = entry
    return {"note": CURATION_NOTE, "targetOrder": CURATION_TARGET_ORDER, "words": words}


def measures(dataset: Dataset) -> dict:
    m = dataset.measures

    def assumed(row: dict, leading: tuple[str, ...]) -> dict:
        out = {key: row[key] for key in leading}
        out["assumption"] = True
        if "note" in row:
            out["note"] = row["note"]
        return out

    units = [assumed({**r, "grams": number(r["grams"])}, ("unit", "grams")) for r in m["units"]]
    by_group = [assumed({**r, "grams": number(r["grams"])}, ("group", "unit", "grams"))
                for r in m["byGroup"]]
    by_ingredient = []
    densities = [assumed({**r, "gramsPerMl": number(r["gramsPerMl"])}, ("group", "gramsPerMl"))
                 for r in m["densities"]]
    for word in catalog_order(dataset.words):
        for unit, spec in word.measures.items():
            row = assumed({"name": word.name, "unit": unit, "grams": number(spec["grams"]),
                           **{k: spec[k] for k in ("note",) if k in spec}},
                          ("name", "unit", "grams"))
            if "state" in spec:
                row["state"] = spec["state"]
            by_ingredient.append(row)
        if word.density is not None:
            densities.append(assumed(
                {"name": word.name, "gramsPerMl": number(word.density["gramsPerMl"]),
                 **{k: word.density[k] for k in ("note",) if k in word.density}},
                ("name", "gramsPerMl"),
            ))
    return {
        "note": m["note"],
        "assumptionNote": m["assumptionNote"],
        "unitRule": m["unitRule"],
        "units": units,
        "byGroup": by_group,
        "byIngredient": by_ingredient,
        "densities": densities,
    }


def aisles(dataset: Dataset) -> dict:
    letters = dataset.aisles["letters"]
    return {
        "note": dataset.aisles["note"],
        "groups": [
            {
                "group": letter,
                "category": letters[letter].get("category"),
                "included": boolean(letters[letter].get("include", "false"))
                or bool(letters[letter].get("special_include_codes")),
                "note": letters[letter].get("note", ""),
            }
            for letter in sorted(letters)
        ],
    }


def group_codes(aisles_document: dict) -> dict:
    """`Data/aisles.yaml` in the shape `extract_bls.py` has always taken
    `group_codes.json` in: booleans as booleans, lists as lists."""
    return {
        "global_exclude_keywords": aisles_document.get("global_exclude_keywords", []),
        "letters": {
            letter: {**cfg, "include": boolean(cfg.get("include", "false"))}
            for letter, cfg in aisles_document["letters"].items()
        },
    }


def load_group_codes(data: Path = DATA) -> dict:
    return group_codes(load_yaml(data / "aisles.yaml"))


def community(dataset: Dataset) -> dict:
    by_name = {word.name: word for word in dataset.words}
    entries = []
    for word in dataset.words:
        for row in inline_rows(word):
            entries.append({
                "code": row["code"],
                "name": row["name"],
                "group": row.get("group", row["code"][0]),
                "category": row.get("category", category_of(word, by_name)),
                "source": row["source"],
                "perHundredGrams": {k: number(v) for k, v in row["per100g"].items()},
            })
    header = dataset.sources["supplements"]
    return {
        "datasetVersion": header["datasetVersion"],
        "release": header["release"],
        "license": header["license"],
        "attribution": header["attribution"],
        "changeNote": header["changeNote"],
        "entries": sorted(entries, key=lambda e: e["code"]),
    }


def sources(dataset: Dataset) -> dict:
    """Every source as it asks to be named, in the order `sources.yaml`
    writes them: what CC BY 4.0 asks the app to show."""
    return {"sources": [
        {
            "id": source_id,
            "title": source["title"],
            "datasetVersion": source["datasetVersion"],
            "release": source["release"],
            "license": source["license"],
            "licenseURL": source["licenseURL"],
            "attribution": source["attribution"],
            "changeNote": source["changeNote"],
        }
        for source_id, source in dataset.sources.items()
    ]}


def load_sources(data: Path = DATA) -> dict:
    return load_yaml(data / "sources.yaml")


def ids(dataset: Dataset) -> dict:
    """The rename map: every absorbed id pointing at the entry that absorbed
    it, and the retired ids. An id in neither and not in the catalog comes
    from a newer data version; the app leaves a row with it alone."""
    return {
        "renamed": dict(sorted(
            (old, word.id) for word in dataset.words for old in word.formerly
        )),
        "retired": sorted(dataset.retired),
    }


def dump_json(data) -> str:
    # No trailing newline, as the resources have always been written.
    return json.dumps(data, indent=1, ensure_ascii=False)


def compile_data(data: Path = DATA, resources: Path = RESOURCES) -> tuple[dict[str, str], list[str], str]:
    """The resources by file name, the warnings, and `released-ids.txt`."""
    dataset = load_dataset(data, resources)
    check(dataset)
    return {
        "kitchen_words.json": dump_json(kitchen_words(dataset)),
        "curation.json": dump_json(curation(dataset)),
        "measures.json": dump_json(measures(dataset)),
        "aisles.json": dump_json(aisles(dataset)),
        "community.json": dump_json(community(dataset)),
        "sources.json": dump_json(sources(dataset)),
        "ids.json": dump_json(ids(dataset)),
    }, dataset.warnings, released_ids(dataset)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="compile in memory and fail if the resources differ")
    parser.add_argument("--since", metavar="REF",
                        help="with --check: also fail if Data/released-ids.txt lost an "
                             "id it had at this git revision")
    parser.add_argument("--data", type=Path, default=DATA)
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    args = parser.parse_args()

    try:
        outputs, warnings, released = compile_data(args.data, args.resources)
    except DataError as error:
        print(f"Data/ does not compile:\n{error}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    released_path = args.data / "released-ids.txt"

    if args.check:
        stale = [
            name for name, text in outputs.items()
            if not (args.resources / name).exists()
            or (args.resources / name).read_text(encoding="utf-8") != text
        ]
        if not released_path.exists() or released_path.read_text(encoding="utf-8") != released:
            stale.append(relative(released_path))
        if stale:
            print("The resources differ from compile(Data/): " + ", ".join(stale) + ".\n"
                  "Edit Data/, not the resources, and run: python3 Scripts/data/compile.py",
                  file=sys.stderr)
            return 1
        if args.since:
            lost = lost_ids(released_at(args.since, released_path), released)
            if lost:
                print(f"Data/released-ids.txt lost {', '.join(lost)} since {args.since}. "
                      f"The list only grows: put the ids back, and rename or retire them "
                      f"in Data/ instead.", file=sys.stderr)
                return 1
        print(f"Resources match compile(Data/): {', '.join(outputs)}")
        return 0

    for name, text in outputs.items():
        (args.resources / name).write_text(text, encoding="utf-8")
    released_path.write_text(released, encoding="utf-8")
    print(f"Wrote {', '.join(outputs)} to {relative(args.resources)}, "
          f"and {relative(released_path)}")
    return 0


def released_at(ref: str, path: Path) -> str:
    """The released-ids list as it was at a git revision; empty before it
    existed. An unknown revision is an error, not an empty list."""
    known = subprocess.run(["git", "cat-file", "-e", f"{ref}^{{commit}}"],
                           cwd=REPO_ROOT, capture_output=True)
    if known.returncode != 0:
        raise SystemExit(f"--since: {ref!r} is not a commit this checkout has")
    result = subprocess.run(
        ["git", "show", f"{ref}:{path.resolve().relative_to(REPO_ROOT).as_posix()}"],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else ""


if __name__ == "__main__":
    sys.exit(main())
