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

`community.json` is read the same way and for the same reason - the curation
may name a code in it - but it is nobody's output: it is hand-kept, and the
only file of shipped rows that a person edits directly.

It cannot and does not touch `bls.json`, `community.json`, `measures.json` or
`aisles.json`; for anything that changes the BLS rows themselves, use
`build_data.py`.

Usage:
    python3 rebuild_synonyms.py [--dry-run]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from build_data import (
    HERE, RESOURCES, SynonymBuilder, dump_json, load, rows_from_supplements,
)


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
    supplements = rows_from_supplements(args.resources)
    builder = SynonymBuilder(load(args.kitchen_words), load(args.curation))
    synonyms = builder.build(rows, supplements=supplements)
    stats = builder.stats

    print(f"BLS rows read: {len(rows)}")
    print(f"Supplement rows read (community.json): {len(supplements)}")
    print(f"Words total: {len(synonyms)}")
    print(f"  curated (kitchen_words.json): {stats['curated_words']}")
    print(f"  from BLS names: {stats['bls_words']}")
    print(f"Varieties (own word, parent named): {len(stats['variants'])}")
    print(f"Words without any target (identity only, no nutrition): "
          f"{len(stats['curated_without_targets'])}")
    print(f"  {stats['curated_without_targets']}")
    print(f"Prefix candidates attached: {stats['prefix_candidates']}")
    print(f"Slashed names split: {stats['slash_split_words']} "
          f"(+{stats['slash_split_spellings']} spellings)")
    if stats["slash_split_absorbed"]:
        print(f"  absorbed into the word that already meant the row: "
              f"{len(stats['slash_split_absorbed'])}")
        for base, owner in stats["slash_split_absorbed"][:6]:
            print(f"    {base}  ->  spelling of {owner}")
    if stats["slash_split_refused"]:
        print(f"  refused, name already taken: {len(stats['slash_split_refused'])} "
              f"{stats['slash_split_refused'][:5]}")
    print(f"Overlay conflicts (heavier claim wins, loser kept as candidate): "
          f"{len(stats['overlay_conflicts'])}")
    for owner, base, state, code in stats["overlay_conflicts"][:8]:
        print(f"  {owner}: BLS '{base}' [{state}] {code} -> candidate")
    if stats["unreachable_base_names"]:
        print(f"!! base names no spelling reaches any more: "
              f"{len(stats['unreachable_base_names'])} "
              f"{stats['unreachable_base_names'][:5]}")
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
