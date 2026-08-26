#!/usr/bin/env python3
"""Rebuild `synonyms.json` from the shipped `bls.json` and the curation.

`build_data.py` is the whole pipeline and needs the workbook, which is not in
the repo. But a *curation* change - a word gaining an alias, a variety moving
out of an alias list into a word of its own - touches only the mapping half,
and the rows it maps onto are already in `bls.json`, exactly as the workbook
left them. So this reads them back, runs the same `SynonymBuilder` over them,
and writes `synonyms.json`.

Same builder, deliberately: two paths producing the table would drift, and the
one that runs less often would be the one that is wrong. A full re-run with the
workbook must produce the same file - `bls.json` is `build_data.py`'s own
output, not a second source.

It cannot and does not touch `bls.json`, `measures.json` or `aisles.json`; for
anything that changes the rows themselves, use `build_data.py`.

Usage:
    python3 rebuild_synonyms.py [--dry-run]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from build_data import HERE, RESOURCES, SynonymBuilder, dump_json, load


def rows_from_bls(bls: dict) -> list[dict]:
    """`bls.json` entries in the shape `extract_bls` hands the builder."""
    return [
        {
            "blsCode": entry["code"],
            "germanName": entry["name"],
            "category": entry["category"],
            "nutrients": entry["perHundredGrams"],
        }
        for entry in bls["entries"]
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kitchen-words", type=Path, default=HERE / "kitchen_words.json")
    parser.add_argument("--curation", type=Path, default=HERE / "curation.json")
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    parser.add_argument("--dry-run", action="store_true", help="Report without writing")
    args = parser.parse_args()

    rows = rows_from_bls(load(args.resources / "bls.json"))
    builder = SynonymBuilder(load(args.kitchen_words), load(args.curation))
    synonyms = builder.build(rows)
    stats = builder.stats

    print(f"BLS rows read: {len(rows)}")
    print(f"Words total: {len(synonyms)}")
    print(f"  curated (kitchen_words.json): {stats['curated_words']}")
    print(f"  from BLS names: {stats['bls_words']}")
    print(f"Varieties (own word, parent named): {len(stats['variants'])}")
    print(f"Words without any target (identity only, no nutrition): "
          f"{len(stats['curated_without_targets'])}")
    print(f"  {stats['curated_without_targets']}")
    print(f"Prefix candidates attached: {stats['prefix_candidates']}")
    if stats["unknown_parents"]:
        print(f"!! varieties naming a parent that is not a word: {stats['unknown_parents']}")
    if stats["curation_unknown_codes"]:
        print(f"!! curation names codes bls.json does not have: {stats['curation_unknown_codes']}")
    if stats["curation_unused_words"]:
        print(f"!! curation names words kitchen_words.json does not have: "
              f"{stats['curation_unused_words']}")

    if args.dry_run:
        print("\n--dry-run: not writing any file.")
        return

    dump_json({"words": synonyms}, args.resources / "synonyms.json")
    print(f"\nWrote synonyms.json to {args.resources}")


if __name__ == "__main__":
    raise SystemExit(main())
