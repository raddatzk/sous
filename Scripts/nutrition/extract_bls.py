#!/usr/bin/env python3
"""Extract base-ingredient rows from the BLS 4.0 main data workbook.

Reads ``BLS_4_0_Daten_2025_DE.xlsx`` (sheet ``BLS_4_0_Daten_2025_DE``), applies the
food-group include/category/exclude decisions documented in ``group_codes.json``,
and returns one dict per surviving row:

    {"blsCode": "G541100", "germanName": "Gemüsepaprika grün, roh",
     "category": "vegetables", "nutrients": {"kcal": 20, "proteinG": 1.1, ...}}

Column lookup is intentionally NOT based on fixed offsets: the workbook layout is
"code, Datenherkunft, Referenz" triplets per nutrient, and the exact column index
shifts depending on which nutrients a given BLS export includes. Instead we search
the header row for a cell whose text starts with "<CODE> " (e.g. "ENERCC Energie
(Kilokalorien) [kcal/100g]" for code "ENERCC") and cache the resulting column index.

Usage:
    python3 extract_bls.py <path-to-BLS_4_0_Daten_2025_DE.xlsx> [--group-codes group_codes.json]

Run standalone it prints summary counts and (with --dump) writes the extracted rows
to a JSON file for inspection. Normally it is imported by merge_states.py instead.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import openpyxl

SHEET_NAME = "BLS_4_0_Daten_2025_DE"

# target field -> BLS nutrient code. VITAA falls back to VITA when blank (see
# extract_nutrients below) because BLS only fills one of the two Vitamin A
# measures for a lot of rows.
NUTRIENT_CODES: dict[str, str] = {
    "kcal": "ENERCC",
    "proteinG": "PROT625",
    "fatG": "FAT",
    "saturatedFatG": "FASAT",
    "carbsG": "CHO",
    "sugarG": "SUGAR",
    "fiberG": "FIBT",
    "sodiumMg": "NA",
    "vitaminAMcg": "VITAA",
    "vitaminCMg": "VITC",
    "vitaminDMcg": "VITD",
    "vitaminEMg": "VITE",
    "calciumMg": "CA",
    "ironMg": "FE",
    "magnesiumMg": "MG",
    "potassiumMg": "K",
}
VITAMIN_A_FALLBACK_CODE = "VITA"


def load_group_codes(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def find_header_columns(header_row: tuple, codes: set[str]) -> dict[str, int]:
    """Map each BLS nutrient code to its value column index by searching the header.

    A header cell for a value column looks like "ENERCC Energie (Kilokalorien)
    [kcal/100g]" - i.e. "<CODE> " followed by a human-readable description. We
    match on that prefix rather than assuming any fixed column offset.
    """
    found: dict[str, int] = {}
    remaining = set(codes)
    for idx, cell in enumerate(header_row):
        if not cell or not remaining:
            continue
        text = str(cell)
        for code in list(remaining):
            if text.startswith(code + " "):
                found[code] = idx
                remaining.discard(code)
    missing = codes - found.keys()
    if missing:
        raise RuntimeError(f"Could not locate header column(s) for BLS code(s): {sorted(missing)}")
    return found


def _round(value):
    if isinstance(value, float):
        # BLS floats already come out of openpyxl with float precision noise
        # occasionally; keep a sane number of decimals for a human-diffable file.
        rounded = round(value, 4)
        return int(rounded) if rounded == int(rounded) else rounded
    return value


def extract_nutrients(row: tuple, col_by_code: dict[str, int]) -> dict:
    nutrients = {}
    for field, code in NUTRIENT_CODES.items():
        value = row[col_by_code[code]]
        if (value is None or value == "") and code == "VITAA":
            value = row[col_by_code[VITAMIN_A_FALLBACK_CODE]]
        if value is None or value == "":
            continue  # omit rather than inventing a zero
        if not isinstance(value, (int, float)):
            # Defensive: BLS sometimes has stray text like "Spur" (trace) in a
            # value cell; skip rather than crash the whole pipeline on it.
            continue
        nutrients[field] = _round(value)
    return nutrients


class RowClassifier:
    """Applies group_codes.json's per-letter include/category/override rules."""

    def __init__(self, group_codes: dict):
        self.global_exclude_keywords = [
            kw.lower() for kw in group_codes.get("global_exclude_keywords", [])
        ]
        self.letters = group_codes["letters"]

    def classify(self, bls_code: str, german_name: str) -> str | None:
        """Return the target category for this row, or None if it should be dropped."""
        name_lower = german_name.lower()
        for kw in self.global_exclude_keywords:
            if kw in name_lower:
                return None

        letter = bls_code[0]
        letter_cfg = self.letters.get(letter)
        if letter_cfg is None:
            return None

        special = letter_cfg.get("special_include_codes", {})
        if bls_code in special:
            return special[bls_code]

        broth_category = _broth_override_category(letter, german_name)
        if broth_category is not None:
            return broth_category

        if not letter_cfg.get("include", False):
            return None

        for rule in letter_cfg.get("overrides", []):
            if _rule_matches(rule, german_name):
                if rule.get("action") == "exclude":
                    return None
                return rule["category"]

        return letter_cfg.get("category")


def _rule_matches(rule: dict, german_name: str) -> bool:
    mode = rule["mode"]
    keywords = rule["keywords"]
    if mode == "contains":
        name_lower = german_name.lower()
        return any(kw.lower() in name_lower for kw in keywords)
    if mode == "starts_with":
        return any(german_name.startswith(kw) for kw in keywords)
    raise ValueError(f"Unknown rule mode: {mode}")


# See group_codes.json's "X"/"Y" notes for the full rationale. Matches names like
# "Hühnerbrühe", "Doppelte Rinderkraftbrühe", "Geflügelkraftbrühe (Huhn)",
# "Fleischbrühe (Rind)" but NOT "Tomatensuppe aus frischen Tomaten und
# Gemüsebrühe" or "Maultaschen ... gegart in Fleischbrühe".
BROTH_NAME_RE = re.compile(
    r"^(?:[A-ZÄÖÜ][a-zäöüß]+\s+)?[A-Za-zÄÖÜäöüß]*[Bb]rühe(?:\s*\([A-Za-zÄÖÜäöüß]+\))?\Z"
)
BROTH_OVERRIDE_LETTERS = {"X", "Y"}
BROTH_OVERRIDE_CATEGORY = "canned"


def _broth_override_category(letter: str, german_name: str) -> str | None:
    if letter not in BROTH_OVERRIDE_LETTERS:
        return None
    if BROTH_NAME_RE.match(german_name.strip()):
        return BROTH_OVERRIDE_CATEGORY
    return None


def extract_rows(xlsx_path: Path, group_codes: dict) -> tuple[list[dict], dict]:
    """Returns (rows, stats). stats has counts useful for the final report."""
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb[SHEET_NAME]
    row_iter = ws.iter_rows(values_only=True)
    header = next(row_iter)

    needed_codes = set(NUTRIENT_CODES.values()) | {VITAMIN_A_FALLBACK_CODE}
    col_by_code = find_header_columns(header, needed_codes)

    classifier = RowClassifier(group_codes)

    rows: list[dict] = []
    stats = {
        "total_source_rows": 0,
        "skipped_missing_code_or_name": 0,
        "skipped_by_group_filter": 0,
        "skipped_all_nutrients_blank": 0,
        "included_by_letter": {},
    }

    for raw_row in row_iter:
        stats["total_source_rows"] += 1
        bls_code = raw_row[0]
        german_name = raw_row[1]
        if not bls_code or not german_name:
            stats["skipped_missing_code_or_name"] += 1
            continue
        bls_code = str(bls_code).strip()
        german_name = str(german_name).strip()

        category = classifier.classify(bls_code, german_name)
        if category is None:
            stats["skipped_by_group_filter"] += 1
            continue

        nutrients = extract_nutrients(raw_row, col_by_code)
        if not nutrients:
            stats["skipped_all_nutrients_blank"] += 1
            continue

        rows.append(
            {
                "blsCode": bls_code,
                "germanName": german_name,
                "category": category,
                "nutrients": nutrients,
            }
        )
        letter = bls_code[0]
        stats["included_by_letter"][letter] = stats["included_by_letter"].get(letter, 0) + 1

    return rows, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xlsx_path", type=Path, help="Path to BLS_4_0_Daten_2025_DE.xlsx")
    parser.add_argument(
        "--group-codes",
        type=Path,
        default=Path(__file__).parent / "group_codes.json",
        help="Path to group_codes.json",
    )
    parser.add_argument("--dump", type=Path, help="Optional path to write extracted rows as JSON")
    args = parser.parse_args()

    group_codes = load_group_codes(args.group_codes)
    rows, stats = extract_rows(args.xlsx_path, group_codes)

    print(f"Total source rows: {stats['total_source_rows']}")
    print(f"Skipped (missing code/name): {stats['skipped_missing_code_or_name']}")
    print(f"Skipped (group filter / excluded): {stats['skipped_by_group_filter']}")
    print(f"Skipped (all 16 nutrient fields blank): {stats['skipped_all_nutrients_blank']}")
    print(f"Included: {len(rows)}")
    print("Included by letter:")
    for letter in sorted(stats["included_by_letter"]):
        print(f"  {letter}: {stats['included_by_letter'][letter]}")

    if args.dump:
        with open(args.dump, "w", encoding="utf-8") as f:
            json.dump(rows, f, indent=1, ensure_ascii=False)
        print(f"Wrote {len(rows)} rows to {args.dump}")


if __name__ == "__main__":
    sys.exit(main())
