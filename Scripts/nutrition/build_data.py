#!/usr/bin/env python3
"""Build `bls.json` from the BLS workbook.

This is the one generated file the curation does not produce: 3,983 BLS rows,
each with its SBLS code, name, food group, aisle category and 16 nutrient
fields per 100 g, unchanged and unaveraged. Everything else under Resources is
compiled from `Data/` by `Scripts/data/compile.py`.

Inputs:

  - the xlsx (not in the repo, see README)
  - `Data/aisles.yaml`   which BLS letters are in scope, their category, and
                         the per-letter keyword overrides
  - `Data/sources.yaml`  the release, licence and attribution bls.json opens
                         with
  - `Data/ingredients/`  every code an ingredient names is kept even where the
                         group filter would drop it, with that ingredient's
                         category

Usage:
    python3 build_data.py <path-to-BLS_4_0_Daten_2025_DE.xlsx> [--dry-run]

Afterwards run `python3 Scripts/data/compile.py --check`: it fails if an
ingredient names a code the new bls.json no longer has.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import extract_bls

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "Scripts/data"))
import compile as data_compiler  # noqa: E402

RESOURCES = REPO_ROOT / "SousKit/Sources/SousKit/Resources"

def build_bls(rows: list[dict], source: dict) -> dict:
    """The rows, headed by what `Data/sources.yaml` says about the release:
    the shipped data names its version and what CC BY 4.0 asks it to say,
    from the same block the sources screen reads."""
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
        "datasetVersion": source["datasetVersion"],
        "release": source["release"],
        "license": source["license"],
        "attribution": source["attribution"],
        "changeNote": source["changeNote"],
        "entries": entries,
    }


def forced_codes(data: Path, resources: Path) -> dict[str, str]:
    """Every code an ingredient names as a basis, with its category.

    A code the curation names is a code the cook is meant to get, whatever the
    group filter thinks of its letter. It carries the category of the word
    that asked for it.
    """
    dataset = data_compiler.load_dataset(data, resources)
    by_name = {word.name: word for word in dataset.words}
    return {
        code: data_compiler.category_of(word, by_name)
        for word in data_compiler.catalog_order(dataset.words)
        for _, code in data_compiler.codes_of(word)
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xlsx_path", type=Path, help="Path to BLS_4_0_Daten_2025_DE.xlsx")
    parser.add_argument("--data", type=Path, default=data_compiler.DATA)
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    parser.add_argument("--dry-run", action="store_true", help="Report without writing")
    args = parser.parse_args()

    group_codes = data_compiler.load_group_codes(args.data)
    force = forced_codes(args.data, args.resources)
    rows, stats = extract_bls.extract_rows(args.xlsx_path, group_codes, force)
    bls = build_bls(rows, data_compiler.load_sources(args.data)["bls"])

    print(f"Source rows: {stats['total_source_rows']}")
    print(f"Skipped (group filter): {stats['skipped_by_group_filter']}")
    print(f"Skipped (all nutrients blank): {stats['skipped_all_nutrients_blank']}")
    print(f"Forced in by the curation (past the group filter): {len(stats['forced_in'])}")
    for code, name in stats["forced_in"]:
        print(f"  {code} {name}")
    print(f"bls.json entries: {len(bls['entries'])}")
    shipped = {entry["code"] for entry in bls["entries"]}
    missing = sorted(code for code in force if code not in shipped and not code.startswith("Z"))
    if missing:
        print(f"!! codes Data/ names that the workbook no longer has: {missing}")

    if args.dry_run:
        print("\n--dry-run: not writing any files.")
        return 0
    # No trailing newline, matching how the resource files have always been
    # written, so a re-run with unchanged data produces an empty diff.
    (args.resources / "bls.json").write_text(
        json.dumps(bls, indent=1, ensure_ascii=False), encoding="utf-8"
    )
    print(f"\nWrote bls.json to {args.resources}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
