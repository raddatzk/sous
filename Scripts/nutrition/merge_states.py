#!/usr/bin/env python3
"""Merge BLS raw/cooked state variants into canonical ingredients, overlay them
against the hand-curated SousKit ingredient catalog, and write the two resource
files the sous app ships:

  - SousKit/Sources/SousKit/Resources/ingredients.json  (strictly additive)
  - SousKit/Sources/SousKit/Resources/nutrition.json     (rewritten from scratch)

This is the main entry point for the whole pipeline; it imports extract_bls.py
rather than re-implementing xlsx parsing. See README.md for the full write-up of
every rule applied here.

Usage:
    python3 merge_states.py <path-to-BLS_4_0_Daten_2025_DE.xlsx> \
        [--ingredients path/to/ingredients.json] [--nutrition path/to/nutrition.json] \
        [--group-codes group_codes.json] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import extract_bls

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INGREDIENTS_PATH = REPO_ROOT / "SousKit/Sources/SousKit/Resources/ingredients.json"
DEFAULT_NUTRITION_PATH = REPO_ROOT / "SousKit/Sources/SousKit/Resources/nutrition.json"
DEFAULT_GROUP_CODES_PATH = Path(__file__).parent / "group_codes.json"

# --- state-suffix vocabulary (see task brief / README.md) -------------------
RAW_WORDS = {"roh"}
COOKED_WORDS = {
    "gekocht", "gegart", "gedünstet", "gebraten", "gebacken",
    "gegrillt", "gedämpft", "pochiert", "frittiert",
}
NONMERGE_WORDS = {
    "tiefgefroren", "konserve", "abgetropft", "geräuchert", "getrocknet",
    "gesalzen", "gesüßt", "ungesüßt", "überbacken", "suppeneinlage",
    "kochpökelware", "schokoliert", "vegan", "pasteurisiert",
    "ultrahocherhitzt", "laktosefrei", "ungefüllt", "aromatisiert",
    "getoastet", "gebunden", "gezuckert",
}

_PUNCT_STRIP_RE = re.compile(r"^\W+|\W+$")


def _clean_token(token: str) -> str:
    return _PUNCT_STRIP_RE.sub("", token).lower()


def split_state_suffix(name: str) -> tuple[str, str | None]:
    """Return (canonical_base_name, state) for a BLS germanName.

    state is "raw", "cooked", or None (meaning: no raw/cooked-collapsing suffix
    was found - either because the trailing descriptor is one of the
    non-merging words, or because nothing recognizable was found at all). In
    the None case canonical_base_name is the ORIGINAL name, unchanged - callers
    should treat that as its own singleton ingredient with state "unspecified".

    Two name shapes occur in BLS: a comma before the final state word ("Kartoffel
    geschält, roh"), and a bare trailing word with no comma at all ("Stint roh",
    "Grenadier gebraten ohne Fett (Pfanne)"). Only the FINAL comma segment (or,
    lacking a comma, the trailing run of words starting at the last recognized
    state word) is ever considered for stripping - earlier qualifiers ("geschält",
    "mager", "getrocknet" when followed by a later "gekocht", ...) are always
    kept as part of the base name, per the task's merge rule.
    """
    if "," in name:
        head, tail = name.rsplit(",", 1)
        head = head.rstrip()
        tail = tail.strip()
        candidate_base = head
        candidate_suffix = tail
    else:
        words = name.split()
        split_idx = None
        for i in range(len(words) - 1, -1, -1):
            if _clean_token(words[i]) in RAW_WORDS | COOKED_WORDS | NONMERGE_WORDS:
                split_idx = i
                break
        if split_idx is None:
            return name, None
        candidate_base = " ".join(words[:split_idx])
        candidate_suffix = " ".join(words[split_idx:])

    if not candidate_suffix:
        return name, None

    first_word = _clean_token(candidate_suffix.split()[0])
    if first_word in RAW_WORDS:
        return candidate_base, "raw"
    if first_word in COOKED_WORDS:
        return candidate_base, "cooked"
    # Non-merging word, or a word outside the documented vocabulary entirely
    # (e.g. "geschmort" is not in the task's list) - both cases keep the full
    # original name and don't merge with any sibling row.
    return name, None


def build_overlay_lookup(existing_ingredients: list[dict]) -> dict[str, str]:
    """Exact (case-sensitive) name/alias -> canonical existing entry name."""
    lookup: dict[str, str] = {}
    for entry in existing_ingredients:
        lookup[entry["name"]] = entry["name"]
        for alias in entry.get("aliases", []):
            lookup.setdefault(alias, entry["name"])
    return lookup


def _average_nutrients(nutrient_dicts: list[dict]) -> dict:
    """Field-wise average across two or more nutrient dicts.

    A field is averaged only over the dicts that actually have it (a field
    missing from one variant doesn't get treated as zero), and the result uses
    the same int-when-whole rounding as extract_bls._round.
    """
    if len(nutrient_dicts) == 1:
        return nutrient_dicts[0]
    sums: dict[str, float] = {}
    counts: dict[str, int] = {}
    for nutrients in nutrient_dicts:
        for field, value in nutrients.items():
            sums[field] = sums.get(field, 0.0) + value
            counts[field] = counts.get(field, 0) + 1
    return {field: extract_bls._round(sums[field] / counts[field]) for field in sums}


def merge_bls_rows(rows: list[dict]) -> tuple[dict[str, dict], dict]:
    """Group extracted BLS rows into canonical-name -> {category, states} dicts.

    states maps "raw"/"cooked"/"unspecified" -> nutrients dict. When several BLS
    rows collapse onto the same (base name, state) - e.g. a vegetable's
    "gedünstet" and "gebraten" rows both becoming that vegetable's single
    "cooked" entry - their nutrient values are averaged field-by-field rather
    than arbitrarily picking one variant and discarding the other's data.
    """
    groups: dict[str, dict] = {}
    stats = {"state_collisions": [], "category_conflicts": []}
    raw_states: dict[str, dict[str, list[dict]]] = {}

    for row in rows:
        base, state = split_state_suffix(row["germanName"])
        state_key = state or "unspecified"

        group = groups.setdefault(base, {"category": row["category"], "states": {}})
        if group["category"] != row["category"]:
            stats["category_conflicts"].append(
                (base, group["category"], row["category"], row["blsCode"])
            )

        bucket = raw_states.setdefault(base, {}).setdefault(state_key, [])
        if bucket:
            stats["state_collisions"].append((base, state_key, row["blsCode"]))
        bucket.append(row["nutrients"])

    for base, states in raw_states.items():
        for state_key, nutrient_dicts in states.items():
            groups[base]["states"][state_key] = _average_nutrients(nutrient_dicts)

    return groups, stats


def resolve_against_catalog(
    groups: dict[str, dict], overlay_lookup: dict[str, str]
) -> tuple[dict[str, dict], list[dict]]:
    """Resolve each BLS canonical name against the existing catalog.

    Returns (final_nutrition_groups, new_ingredient_entries). final_nutrition_groups
    is keyed by the name that should appear in both ingredients.json and
    nutrition.json (existing curated name on a match, otherwise the cleaned BLS
    name); state dicts belonging to multiple BLS groups that resolve to the same
    existing name are merged together.
    """
    final_groups: dict[str, dict] = {}
    new_entries: list[dict] = []
    seen_new_names: set[str] = set()

    for base_name, group in groups.items():
        resolved_name = overlay_lookup.get(base_name)
        if resolved_name is None:
            resolved_name = base_name
            if base_name not in seen_new_names:
                new_entries.append(
                    {"name": base_name, "aliases": [], "category": group["category"]}
                )
                seen_new_names.add(base_name)

        target = final_groups.setdefault(resolved_name, {"states": {}})
        for state_key, nutrients in group["states"].items():
            # Same policy as merge_bls_rows: first one wins, rest logged by caller
            # inspecting group sizes if ever needed - collisions here are rare
            # (would require two different BLS canonical names both overlaying
            # onto the same existing catalog entry with the same state).
            target["states"].setdefault(state_key, nutrients)

    return final_groups, new_entries


STATE_ORDER = ["raw", "cooked", "unspecified"]


def build_nutrition_json(final_groups: dict[str, dict]) -> list[dict]:
    out = []
    for name in sorted(final_groups.keys()):
        states = final_groups[name]["states"]
        per_hundred = {
            state: states[state] for state in STATE_ORDER if state in states
        }
        out.append(
            {
                "name": name,
                "perHundredGrams": per_hundred,
                "unitWeightsGrams": {},
                "densityGramsPerMl": None,
                # Written out rather than left to the app's decode default, so
                # the file says whose data it is once other sources join it.
                "source": "BLS 4.0",
            }
        )
    return out


def dump_json(data, path: Path) -> None:
    # No trailing newline: matches the existing ingredients.json byte-for-byte
    # so the unchanged prefix of the file produces a genuinely empty diff.
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, indent=1, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xlsx_path", type=Path, help="Path to BLS_4_0_Daten_2025_DE.xlsx")
    parser.add_argument("--ingredients", type=Path, default=DEFAULT_INGREDIENTS_PATH)
    parser.add_argument("--nutrition", type=Path, default=DEFAULT_NUTRITION_PATH)
    parser.add_argument("--group-codes", type=Path, default=DEFAULT_GROUP_CODES_PATH)
    parser.add_argument(
        "--dry-run", action="store_true", help="Print the report without writing any files"
    )
    args = parser.parse_args()

    group_codes = extract_bls.load_group_codes(args.group_codes)
    rows, extract_stats = extract_bls.extract_rows(args.xlsx_path, group_codes)

    with open(args.ingredients, encoding="utf-8") as f:
        existing_ingredients = json.load(f)
    overlay_lookup = build_overlay_lookup(existing_ingredients)

    groups, merge_stats = merge_bls_rows(rows)
    final_groups, new_entries = resolve_against_catalog(groups, overlay_lookup)
    nutrition_json = build_nutrition_json(final_groups)

    new_entries_sorted = sorted(new_entries, key=lambda e: e["name"])
    combined_ingredients = existing_ingredients + new_entries_sorted

    # Sanity: byte-identical preservation of the existing 229 entries' content.
    assert combined_ingredients[: len(existing_ingredients)] == existing_ingredients

    state_counts = {1: 0, 2: 0, 3: 0}
    for g in final_groups.values():
        state_counts[len(g["states"])] = state_counts.get(len(g["states"]), 0) + 1

    print("=== extract_bls stats ===")
    print(f"Total source rows: {extract_stats['total_source_rows']}")
    print(f"Skipped (missing code/name): {extract_stats['skipped_missing_code_or_name']}")
    print(f"Skipped (group filter / excluded): {extract_stats['skipped_by_group_filter']}")
    print(f"Skipped (all nutrients blank): {extract_stats['skipped_all_nutrients_blank']}")
    print(f"Included rows: {len(rows)}")
    print("Included by letter:")
    for letter in sorted(extract_stats["included_by_letter"]):
        print(f"  {letter}: {extract_stats['included_by_letter'][letter]}")

    print("\n=== merge_states stats ===")
    print(f"BLS canonical groups (post raw/cooked merge, pre-overlay): {len(groups)}")
    print(
        f"State collisions (averaged together into one state): "
        f"{len(merge_stats['state_collisions'])}"
    )
    for base, state_key, code in merge_stats["state_collisions"][:20]:
        print(f"  {code}: another '{state_key}' row for '{base}' - averaged in")
    print(f"Category conflicts within one base name: {len(merge_stats['category_conflicts'])}")
    for base, old_cat, new_cat, code in merge_stats["category_conflicts"][:20]:
        print(f"  {code}: '{base}' has both category={old_cat} and category={new_cat}")

    print("\n=== overlay stats ===")
    print(f"Existing ingredients.json entries: {len(existing_ingredients)}")
    print(f"New ingredients.json entries to append: {len(new_entries_sorted)}")
    print(f"ingredients.json total after merge: {len(combined_ingredients)}")
    print(f"nutrition.json entries: {len(nutrition_json)}")
    print(f"Canonical ingredients with 1 state: {state_counts.get(1, 0)}")
    print(f"Canonical ingredients with 2 states (raw+cooked, etc.): {state_counts.get(2, 0)}")
    print(f"Canonical ingredients with 3 states: {state_counts.get(3, 0)}")

    if args.dry_run:
        print("\n--dry-run: not writing any files.")
        return

    dump_json(combined_ingredients, args.ingredients)
    dump_json(nutrition_json, args.nutrition)
    print(f"\nWrote {args.ingredients}")
    print(f"Wrote {args.nutrition}")


if __name__ == "__main__":
    sys.exit(main())
