#!/usr/bin/env python3
"""Generate `Data/` once from the JSON the catalog was curated in until now.

A one-off: after it has run, `Data/` is the source and `compile.py` turns it
back into the bundled resources. It stays in the repository so the conversion
can be read and re-run against the history, not because anyone should run it
again - a second run would overwrite whatever was curated in YAML since. It
reads files the same commit deletes, so it runs on its parent's tree only.

Reads (all from the resources, which were identical to the pipeline's copies):

  - `kitchen_words.json`  names, aliases, category, parent
  - `curation.json`       per word: codes per state, or "without", the reason
  - `measures.json`       generic units, group weights, per-ingredient weights
                          and densities
  - `community.json`      the rows the BLS does not have
  - `aisles.json` is not read: it is derived from `group_codes.json`, which is
    moved into `Data/aisles.yaml` whole, so the group filter and the aisle
    defaults stay one file.

Writes:

  - `Data/ingredients/<root id>.yaml`  one family per file, varieties nested
  - `Data/products/`                   empty
  - `Data/measures.yaml`               units, group weights, group densities
  - `Data/aisles.yaml`                 BLS group -> category, and the filter
  - `Data/sources.yaml`                what community.json says about itself

Usage:
    python3 Scripts/data/export_yaml.py [--force]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
RESOURCES = REPO_ROOT / "SousKit/Sources/SousKit/Resources"
GROUP_CODES = REPO_ROOT / "Scripts/nutrition/group_codes.json"
DATA = REPO_ROOT / "Data"


class Flow(list):
    """A list written on one line: codes, candidates."""


class FlowMap(dict):
    """A mapping written on one line: a measure without a note."""


class Dumper(yaml.SafeDumper):
    # Indent a list under its key, as the examples in the concept do. PyYAML's
    # default puts the dashes flush with the key.
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


Dumper.add_representer(
    Flow, lambda d, v: d.represent_sequence("tag:yaml.org,2002:seq", v, flow_style=True)
)
Dumper.add_representer(
    FlowMap, lambda d, v: d.represent_mapping("tag:yaml.org,2002:map", v, flow_style=True)
)


def dump_yaml(data, path: Path, header: str | None = None) -> None:
    text = yaml.dump(
        data, Dumper=Dumper, allow_unicode=True, sort_keys=False,
        default_flow_style=False, width=88,
    )
    with open(path, "w", encoding="utf-8") as f:
        if header:
            f.write("".join(f"# {line}\n".rstrip() + "\n" if line else "#\n"
                            for line in header.splitlines()))
        f.write(text)


def load(name: str):
    with open(RESOURCES / name, encoding="utf-8") as f:
        return json.load(f)


def slug(name: str) -> str:
    """`Rote Zwiebel` -> `rote-zwiebel`. Umlauts spelled out, accents dropped."""
    s = name.lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        s = s.replace(a, b)
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def measure_value(row: dict):
    extra = {k: row[k] for k in ("state", "note") if k in row}
    if not extra:
        return row["grams"]
    return {"grams": row["grams"], **extra}


def density_value(row: dict):
    if "note" not in row:
        return row["gramsPerMl"]
    return {"gramsPerMl": row["gramsPerMl"], "note": row["note"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="overwrite an existing Data/")
    args = parser.parse_args()
    if (DATA / "ingredients").exists() and not args.force:
        print("Data/ingredients exists already; it is the source now. --force to overwrite.")
        return 1

    words = load("kitchen_words.json")
    curation = load("curation.json")["words"]
    measures = load("measures.json")
    community = load("community.json")
    with open(GROUP_CODES, encoding="utf-8") as f:
        group_codes = json.load(f)

    by_name = {w["name"]: w for w in words}
    children: dict[str, list[str]] = {}
    for w in words:
        if w.get("parent"):
            children.setdefault(w["parent"], []).append(w["name"])

    def category_of(name: str) -> str:
        w = by_name[name]
        while "category" not in w:
            w = by_name[w["parent"]]
        return w["category"]

    measures_by_name: dict[str, dict] = {}
    for row in measures["byIngredient"]:
        if row["name"] not in by_name:
            raise SystemExit(f"measure for {row['name']!r}, which is no kitchen word")
        measures_by_name.setdefault(row["name"], {})[row["unit"]] = measure_value(row)
    density_by_name = {
        row["name"]: density_value(row) for row in measures["densities"] if "name" in row
    }
    inline_rows = {row["code"]: row for row in community["entries"]}
    used_inline: set[str] = set()

    def nutrition_of(name: str):
        spec = curation.get(name)
        if spec is None:
            return None
        if spec.get("withoutValues"):
            return "without"
        block = {}
        for state, codes in spec["targets"].items():
            items = []
            for code in codes:
                row = inline_rows.get(code)
                if row is None:
                    items.append(code)
                    continue
                used_inline.add(code)
                inline = {"code": code, "name": row["name"]}
                if row["group"] != code[0]:
                    inline["group"] = row["group"]
                if row["category"] != category_of(name):
                    inline["category"] = row["category"]
                inline["source"] = row["source"]
                inline["per100g"] = dict(row["perHundredGrams"])
                items.append(inline)
            block[state] = Flow(items) if all(isinstance(i, str) for i in items) else items
        return block

    def entry(name: str) -> dict:
        w = by_name[name]
        e: dict = {"id": slug(name), "name": name}
        if w["aliases"]:
            e["aliases"] = list(w["aliases"])
        if "category" in w:
            e["category"] = w["category"]
        if name in density_by_name:
            e["density"] = density_by_name[name]
        if name in measures_by_name:
            m = measures_by_name[name]
            e["measures"] = FlowMap(m) if all(not isinstance(v, dict) for v in m.values()) else m
        nutrition = nutrition_of(name)
        if nutrition is not None:
            e["nutrition"] = nutrition
        spec = curation.get(name, {})
        if spec.get("candidates"):
            e["candidates"] = Flow(spec["candidates"])
        if "via" in spec:
            e["via"] = spec["via"]
        if name in children:
            e["varieties"] = [entry(child) for child in children[name]]
        return e

    (DATA / "ingredients").mkdir(parents=True, exist_ok=True)
    (DATA / "products").mkdir(parents=True, exist_ok=True)
    (DATA / "products" / ".gitkeep").touch()
    roots = [w["name"] for w in words if not w.get("parent")]
    for name in roots:
        root = entry(name)
        dump_yaml([root], DATA / "ingredients" / f"{root['id']}.yaml")
    unused = set(inline_rows) - used_inline
    if unused:
        raise SystemExit(f"community rows no word uses: {sorted(unused)}")

    dump_yaml({
        "note": measures["note"],
        "assumptionNote": measures["assumptionNote"],
        "unitRule": measures["unitRule"],
        "units": [{k: v for k, v in row.items() if k != "assumption"} for row in measures["units"]],
        "byGroup": [{k: v for k, v in row.items() if k != "assumption"} for row in measures["byGroup"]],
        "densities": [
            {k: v for k, v in row.items() if k != "assumption"}
            for row in measures["densities"] if "name" not in row
        ],
    }, DATA / "measures.yaml", header=(
        "Measures that belong to a unit or a whole BLS food group. A measure of one\n"
        "ingredient sits on that ingredient, under Data/ingredients/. Every value\n"
        "here is an assumption and is shown with ≈."
    ))

    aisles = load("aisles.json")
    dump_yaml({
        "readme": group_codes["_readme"],
        "note": aisles["note"],
        "global_exclude_keywords": Flow(group_codes["global_exclude_keywords"]),
        "global_exclude_keywords_note": group_codes["global_exclude_keywords_note"],
        "letters": {
            letter: {
                key: ([
                    {k: (Flow(v) if k == "keywords" else v) for k, v in rule.items()}
                    for rule in value
                ] if key == "overrides" else value)
                for key, value in cfg.items()
            }
            for letter, cfg in group_codes["letters"].items()
        },
    }, DATA / "aisles.yaml", header=(
        "BLS food groups: which ones the extraction keeps, and the aisle (category)\n"
        "a row lands in when nothing more specific says. Read by compile.py for\n"
        "aisles.json and by Scripts/nutrition/build_data.py for bls.json."
    ))

    dump_yaml({
        "supplements": {k: v for k, v in community.items() if k != "entries"},
    }, DATA / "sources.yaml", header=(
        "What each data source says about itself: version, release, licence and the\n"
        "attribution it asks for. The rows themselves sit inline on their ingredient."
    ))
    print(f"Wrote {len(roots)} families, measures, aisles and sources to {DATA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
