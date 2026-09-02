#!/usr/bin/env python3
"""Move a BLS word into the kitchen's own list.

The two lists are kept apart on purpose - `kitchen_words.json` is how a cook
writes, the BLS is how a food table writes - and only the kitchen's list is
ever offered while typing. That leaves a job: a word that is plain kitchen
language and happens to also be a BLS row name ("Zucchini", "Backpulver",
"Tomatenmark") belongs in the kitchen's list, and until somebody says so it
is only reachable by looking it up.

This says so. For each name given, it writes the word into
`kitchen_words.json` (name, spellings, category) and its codes into
`curation.json` (the link to the table's rows), taking both from the old
merged `synonyms.json` - which is where that knowledge sat while the build
still derived it.

    ./adopt_words.py --from synonyms.json Zucchini Schalotte Backpulver
    ./adopt_words.py --from synonyms.json --file waved-through.txt

Neither file is ever overwritten wholesale: a word already in the kitchen's
list is left exactly as it stands and reported, because what is written by
hand outranks anything this can work out.
"""
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def dump(data, path):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(data, indent=1, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("words", nargs="*", help="BLS words to adopt")
    parser.add_argument("--file", type=Path, help="One word per line; # comments ignored")
    parser.add_argument("--from", dest="source", type=Path, required=True,
                        help="The merged synonyms.json to take codes and spellings from")
    parser.add_argument("--kitchen-words", type=Path, default=HERE / "kitchen_words.json")
    parser.add_argument("--curation", type=Path, default=HERE / "curation.json")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    wanted = list(args.words)
    if args.file:
        for line in args.file.read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                wanted.append(line)
    if not wanted:
        parser.error("no words given")

    table = {w["word"]: w for w in load(args.source)["words"]}
    kitchen = load(args.kitchen_words)
    curation = load(args.curation)
    known = {entry["name"] for entry in kitchen}

    adopted, skipped, unknown = [], [], []
    for name in wanted:
        if name in known:
            skipped.append(name)
            continue
        word = table.get(name)
        if word is None:
            unknown.append(name)
            continue
        # A variety writes no category of its own unless it differs from its
        # parent's - see the README, "Varieties". "Unless it differs" is the
        # operative half: a genuine override has to survive the adoption.
        parent_category = table.get(word.get("parent", ""), {}).get("category")
        writes_category = "category" in word and (
            not word.get("parent") or word["category"] != parent_category
        )
        kitchen.append({
            "name": name,
            "aliases": word.get("aliases", []),
            **({"category": word["category"]} if writes_category else {}),
            **({"parent": word["parent"]} if word.get("parent") else {}),
        })
        known.add(name)
        # The codes, in the order the old table ranked them: within a state
        # the heaviest first, which is the basis, and the rest alternatives.
        by_state = {}
        for target in sorted(word.get("targets", []), key=lambda t: -t["weight"]):
            by_state.setdefault(target["state"], []).append(target["code"])
        if by_state:
            entry = {"targets": by_state, "via": "BLS-Name, in die Küchenliste übernommen"}
            if word.get("candidates"):
                entry["candidates"] = word["candidates"]
            curation["words"][name] = entry
        adopted.append(name)

    kitchen.sort(key=lambda entry: entry["name"])
    curation["words"] = dict(sorted(curation["words"].items()))

    print(f"adopted: {len(adopted)}")
    for name in adopted:
        print(f"  {name}")
    if skipped:
        print(f"already in the kitchen's list, left alone: {len(skipped)}")
        for name in skipped:
            print(f"  {name}")
    if unknown:
        print(f"!! not a word in {args.source.name}: {unknown}")

    if args.dry_run:
        print("\n--dry-run: not writing.")
        return 0
    dump(kitchen, args.kitchen_words)
    dump(curation, args.curation)
    print(f"\nWrote {args.kitchen_words.name} ({len(kitchen)} words) and "
          f"{args.curation.name} ({len(curation['words'])} mappings).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
