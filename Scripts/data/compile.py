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
  - `Data/schema.json`         the shape all of the above is validated against
  - `Resources/bls.json`       generated from the BLS workbook by
                               `Scripts/nutrition/build_data.py`; read here only
                               to check that every code exists

Writes `kitchen_words.json`, `curation.json`, `measures.json`, `aisles.json`
and `community.json`, in the shapes the app has always read.

The YAML loader is strict, because YAML's conveniences are traps in a data
set: every scalar is read as a string (`no` stays "no", `1.10` stays "1.10",
an EAN keeps its leading zeros), a key written twice is an error, and anchors
are refused. Numbers are converted where the schema says a field is one.

Usage:
    python3 Scripts/data/compile.py            write the resources
    python3 Scripts/data/compile.py --check    fail if the resources differ

Needs PyYAML and jsonschema (`pip install -r Scripts/data/requirements.txt`).
"""
from __future__ import annotations

import argparse
import json
import re
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
    if errors:
        raise DataError("\n".join(errors))

    bls = json.loads((resources / "bls.json").read_text(encoding="utf-8"))
    return Dataset(
        words=words, measures=measures, aisles=aisles, sources=sources,
        bls_codes={row["code"] for row in bls["entries"]},
    )


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


def check(dataset: Dataset) -> None:
    errors: list[str] = []
    warnings = dataset.warnings
    words = dataset.words

    # Ids: a slug, once.
    by_id: dict[str, Word] = {}
    for word in words:
        if word.id in by_id:
            errors.append(f"{word.file}: the id {word.id!r} is used twice "
                          f"({by_id[word.id].name!r} and {word.name!r})")
        by_id[word.id] = word

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
    # written once.
    inline: dict[str, Word] = {}
    for word in words:
        for row in inline_rows(word):
            code = row["code"]
            if code in inline or code in dataset.bls_codes:
                errors.append(f"{word.file}: the inline code {code} is used twice")
            inline[code] = word
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
        row: dict = {"name": word.name, "aliases": word.aliases}
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


def dump_json(data) -> str:
    # No trailing newline, as the resources have always been written.
    return json.dumps(data, indent=1, ensure_ascii=False)


def compile_data(data: Path = DATA, resources: Path = RESOURCES) -> tuple[dict[str, str], list[str]]:
    dataset = load_dataset(data, resources)
    check(dataset)
    return {
        "kitchen_words.json": dump_json(kitchen_words(dataset)),
        "curation.json": dump_json(curation(dataset)),
        "measures.json": dump_json(measures(dataset)),
        "aisles.json": dump_json(aisles(dataset)),
        "community.json": dump_json(community(dataset)),
    }, dataset.warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="compile in memory and fail if the resources differ")
    parser.add_argument("--data", type=Path, default=DATA)
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    args = parser.parse_args()

    try:
        outputs, warnings = compile_data(args.data, args.resources)
    except DataError as error:
        print(f"Data/ does not compile:\n{error}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)

    if args.check:
        stale = [
            name for name, text in outputs.items()
            if not (args.resources / name).exists()
            or (args.resources / name).read_text(encoding="utf-8") != text
        ]
        if stale:
            print("The resources differ from compile(Data/): " + ", ".join(stale) + ".\n"
                  "Edit Data/, not the resources, and run: python3 Scripts/data/compile.py",
                  file=sys.stderr)
            return 1
        print(f"Resources match compile(Data/): {', '.join(outputs)}")
        return 0

    for name, text in outputs.items():
        (args.resources / name).write_text(text, encoding="utf-8")
    print(f"Wrote {', '.join(outputs)} to {relative(args.resources)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
