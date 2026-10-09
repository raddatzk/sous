#!/usr/bin/env python3
"""Turns an approved inbox issue into a change of Community/.

The private inbox repository files shared catalog adjustments as issues, each
with its reports as a ```json sous-catalog``` block (inbox.py). The cook
approves one by labelling it; the inbox's workflow then checks out sous, runs
this script, and opens a pull request with what it wrote. The cook merges it —
the merge is the review — and the merge publishes the data.

Labels (decided with the cook, 2026-10-04; labels only):

    als-alias              the name becomes a spelling of the word the reports
                           most often counted it as
    als-sorte              the name becomes a variety of that word
    neues-wort + kat:<k>   the name becomes a word of its own, without values,
                           in the category <k> (kat:gewürze, kat:gemüse, …)

Only these mechanical cases are written. Values, weights and products are left
for the curator: the script says so, and does not guess.

The edit is made on top of the checkout's main and compiled at once, so the
pull request carries the YAML, the resources, the manifest and the released
ids together. Nothing is written when the data would not compile; the script
reports why instead.

    python3 Scripts/data/approve.py --issue issue.json --inbox owner/inbox --out result.json

`issue.json` is the GitHub issue object (title, number, labels, body).
`result.json` says what happened: {"status": "changed" | "refused" | "waiting",
"message", and for a change "branch", "title", "body", "commit"}.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compile as data_compiler  # noqa: E402
from compile import DataError, normalize  # noqa: E402
from inbox import CATEGORIES, read_block  # noqa: E402

ALIAS, VARIETY, WORD = "als-alias", "als-sorte", "neues-wort"
CATEGORY_PREFIX = "kat:"
WORD_VIA = "Aus geteilten Anpassungen übernommen; noch ohne BLS-Zuordnung"


class Refusal(Exception):
    """Why an approval is not written — said on the issue."""


class Waiting(Exception):
    """An approval not complete yet (a category label without `neues-wort`):
    nothing to say."""


# --------------------------------------------------------------------------
# YAML as the files are written

class Flow(list):
    """A list written on one line: codes, candidates."""


class FlowMap(dict):
    """A mapping written on one line: a measure without a note."""


class Dumper(yaml.SafeDumper):
    # Indent a list under its key, as the files do. PyYAML's default puts the
    # dashes flush with the key.
    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


Dumper.add_representer(
    Flow, lambda d, v: d.represent_sequence("tag:yaml.org,2002:seq", v, flow_style=True)
)
Dumper.add_representer(
    FlowMap, lambda d, v: d.represent_mapping("tag:yaml.org,2002:map", v, flow_style=True)
)


def slug(name: str) -> str:
    """`Rote Zwiebel` -> `rote-zwiebel`. Umlauts spelled out, accents dropped."""
    s = name.lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        s = s.replace(a, b)
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def _mark(node: Any) -> Any:
    """Marks what the files write on one line, so a load and dump gives the
    same bytes: code lists, candidates, measures without notes, EANs, and an
    alias's unit."""
    if isinstance(node, list):
        return [_mark(x) for x in node]
    if not isinstance(node, dict):
        return node
    out = {}
    for key, value in node.items():
        if key == "nutrition" and isinstance(value, dict):
            value = {state: Flow(codes) if isinstance(codes, list) and all(isinstance(c, str) for c in codes)
                     else _mark(codes) for state, codes in value.items()}
        elif key in ("candidates", "ean") and isinstance(value, list):
            value = Flow(value)
        elif key == "measures" and isinstance(value, dict) \
                and all(not isinstance(v, (dict, list)) for v in value.values()):
            value = FlowMap(value)
        elif key == "aliases" and isinstance(value, list):
            value = [{a: FlowMap(u) for a, u in x.items()} if isinstance(x, dict) else x for x in value]
        else:
            value = _mark(value)
        out[key] = value
    return out


def dump(entries: List[Dict[str, Any]]) -> str:
    return yaml.dump(_mark(entries), Dumper=Dumper, allow_unicode=True, sort_keys=False,
                     default_flow_style=False, width=88)


def load_for_edit(path: Path) -> List[Dict[str, Any]]:
    """The file's entries, refused if writing them back would change more
    than the edit — a comment, or a form the dumper does not reproduce."""
    text = path.read_text(encoding="utf-8")
    entries = yaml.safe_load(text)
    if dump(entries) != text:
        raise Refusal(f"`{path.name}` lässt sich nicht verlustfrei neu schreiben "
                      f"(Kommentar oder Sonderform). Bitte von Hand übernehmen.")
    return entries


def find_entry(entries: List[Dict[str, Any]], entry_id: str) -> Optional[Dict[str, Any]]:
    for entry in entries:
        if entry.get("id") == entry_id:
            return entry
        found = find_entry(entry.get("varieties") or [], entry_id)
        if found:
            return found
    return None


def with_key_after(entry: Dict[str, Any], key: str, value: Any, after: str) -> Dict[str, Any]:
    """The entry with `key` placed right after `after`, in the files' order."""
    out: Dict[str, Any] = {}
    for k, v in entry.items():
        out[k] = v
        if k == after:
            out[key] = value
    return out


# --------------------------------------------------------------------------
# What the labels ask for

def decide(issue: Dict[str, Any]) -> Tuple[str, Dict[str, Any], Dict[str, Any]]:
    """The action, its arguments and the block — or a Refusal / Waiting."""
    labels = {label["name"] if isinstance(label, dict) else label for label in issue.get("labels", [])}
    actions = [a for a in (ALIAS, VARIETY, WORD) if a in labels]
    categories = sorted(label[len(CATEGORY_PREFIX):] for label in labels if label.startswith(CATEGORY_PREFIX))
    if not actions:
        raise Waiting()
    if len(actions) > 1:
        raise Refusal(f"Mehrere Freigaben zugleich ({', '.join(actions)}). Bitte nur eine setzen.")
    block = read_block(issue.get("body") or "")
    if not block:
        raise Refusal("Kein lesbarer `sous-catalog`-Block im Issue.")
    action = actions[0]

    if action == WORD:
        if not categories:
            raise Refusal("Für `neues-wort` fehlt die Kategorie: bitte ein `kat:`-Label setzen "
                          f"({', '.join(CATEGORY_PREFIX + c for c in CATEGORIES)}).")
        if len(categories) > 1:
            raise Refusal(f"Mehrere Kategorien ({', '.join(categories)}). Bitte nur ein `kat:`-Label.")
        if categories[0] not in CATEGORIES:
            raise Refusal(f"Unbekannte Kategorie `kat:{categories[0]}`.")
        return action, {"category": CATEGORIES[categories[0]]}, block

    targets = Counter()
    names = {}
    for answer in block.get("answers", []):
        target = answer.get("target") or {}
        if answer.get("kind") == "countsAs" and target.get("id"):
            targets[target["id"]] += answer.get("reports", 1)
            names[target["id"]] = target.get("name", target["id"])
    if not targets:
        raise Refusal("Die Meldungen nennen kein Wort, als das der Name zählt. "
                      "Alias oder Sorte bitte von Hand übernehmen.")
    ranked = targets.most_common()
    if len(ranked) > 1 and ranked[0][1] == ranked[1][1]:
        tied = ", ".join(f"{names[t]} (`{t}`)" for t, n in ranked if n == ranked[0][1])
        raise Refusal(f"Die Meldungen sind uneins, worauf der Name zählt: {tied}. Bitte von Hand übernehmen.")
    return action, {"target": ranked[0][0]}, block


# --------------------------------------------------------------------------
# Writing

def apply(action: str, args: Dict[str, Any], name: str, data: Path, resources: Path) -> Dict[str, str]:
    """Edits Community/, compiles, and writes the resources. Returns the change's
    title, summary and commit message. On a refusal Community/ is left as it was."""
    if "," in name or "(" in name or ")" in name:
        raise Refusal(f"„{name}“ enthält Komma oder Klammer; als Katalogname bitte von Hand anlegen.")
    try:
        # What compile.py warns about already, so the pull request names only
        # what this change adds.
        _, known_warnings, _ = data_compiler.compile_data(data, resources)
    except DataError as error:
        raise Refusal(f"Der Katalog auf main kompiliert schon vorher nicht:\n```\n{error}\n```")
    dataset = data_compiler.load_dataset(data, resources)
    by_spelling = {normalize(s): w for w in dataset.words for s in w.spellings}
    known = by_spelling.get(normalize(name))
    if known:
        raise Refusal(f"„{name}“ kennt der Katalog schon, als {known.name} (`{known.id}`).")
    taken = {w.id for w in dataset.words} | {f for w in dataset.words for f in w.formerly}
    taken |= set(data_compiler.read_released(data / "released-ids.txt"))

    written: Dict[Path, Optional[str]] = {}

    def write(path: Path, text: str) -> None:
        written.setdefault(path, path.read_text(encoding="utf-8") if path.exists() else None)
        path.write_text(text, encoding="utf-8")

    if action in (ALIAS, VARIETY):
        target_id = args["target"]
        target = next((w for w in dataset.words if w.id == target_id), None)
        if target is None:
            target = next((w for w in dataset.words if target_id in w.formerly), None)
        if target is None:
            raise Refusal(f"Das Ziel `{target_id}` gibt es im Katalog nicht (mehr).")
        if target.kind == "product":
            raise Refusal(f"Das Ziel {target.name} ist ein Produkt; ein Name wird nie öffentlicher Alias einer Marke.")
        # `file` is the path compile.py read, relative to the repository or not.
        path = data / "ingredients" / Path(target.file).name
        entries = load_for_edit(path)
        entry = find_entry(entries, target.id)
        if entry is None:
            raise Refusal(f"`{target.id}` steht nicht in `{path.name}`.")
        if action == ALIAS:
            if "aliases" in entry:
                replacement = dict(entry, aliases=entry["aliases"] + [name])
            else:
                replacement = with_key_after(entry, "aliases", [name], "name")
            title = f"„{name}“ als Schreibweise von {target.name}"
            commit = f"Spell {target.name} also as „{name}“"
        else:
            new_id = slug(name)
            if not new_id or new_id in taken:
                raise Refusal(f"Die Id `{new_id}` ist schon vergeben; bitte von Hand anlegen.")
            variety = {"id": new_id, "name": name}
            replacement = dict(entry, varieties=(entry.get("varieties") or []) + [variety])
            title = f"„{name}“ als Sorte von {target.name}"
            commit = f"Add „{name}“ as a variety of {target.name}"
        entry.clear()
        entry.update(replacement)
        write(path, dump(entries))
        summary = title
    else:
        new_id = slug(name)
        path = data / "ingredients" / f"{new_id}.yaml"
        if not new_id or new_id in taken or path.exists():
            raise Refusal(f"Die Id `{new_id}` ist schon vergeben; bitte von Hand anlegen.")
        entries = [{"id": new_id, "name": name, "category": args["category"],
                    "nutrition": "without", "via": WORD_VIA}]
        write(path, dump(entries))
        title = f"„{name}“ als neues Wort, ohne Werte"
        commit = f"Add „{name}“ as a word without values"
        summary = f"{title} (Kategorie `{args['category']}`)"

    try:
        outputs, warnings, released = data_compiler.compile_data(data, resources)
    except DataError as error:
        for path, before in written.items():
            if before is None:
                path.unlink()
            else:
                path.write_text(before, encoding="utf-8")
        raise Refusal(f"So kompiliert der Katalog nicht:\n```\n{error}\n```")
    for file_name, text in outputs.items():
        (resources / file_name).write_text(text, encoding="utf-8")
    (data / "released-ids.txt").write_text(released, encoding="utf-8")
    added = [w for w in warnings if w not in known_warnings]
    return {"title": title, "summary": summary, "commit": commit, "warnings": "\n".join(added)}


def leftovers(block: Dict[str, Any]) -> List[str]:
    """What the reports said beyond the name — values, weights, products —
    which 10b leaves for the curator."""
    from inbox import describe
    return [describe(a) for a in block.get("answers", [])
            if a.get("values") or a.get("weights") or a.get("kind") in ("values", "product")]


def run(issue: Dict[str, Any], inbox: str, data: Path, resources: Path) -> Dict[str, Any]:
    try:
        action, args, block = decide(issue)
        change = apply(action, args, block["name"], data, resources)
    except Waiting:
        return {"status": "waiting", "message": ""}
    except Refusal as refusal:
        return {"status": "refused", "message": f"Nicht übernommen: {refusal}"}
    number = issue["number"]
    rest = leftovers(block)
    manual = ("\n\nNicht mechanisch, bitte von Hand:\n" + "\n".join(f"- {r}" for r in rest)) if rest else ""
    body = (f"{change['summary']}.\n\n"
            f"Aus der Katalog-Inbox: {inbox}#{number} (privat). Freigegeben mit dem Label "
            f"`{action}`; Community/, die Ressourcen und das Manifest sind neu kompiliert.\n\n"
            f"Der Merge veröffentlicht den Katalog nach Development und Production.")
    if change["warnings"]:
        body += f"\n\nHinweise von compile.py:\n```\n{change['warnings']}\n```"
    return {
        "status": "changed",
        "branch": f"inbox/{number}-{slug(block['name'])}",
        "title": f"Katalog: {change['title']}",
        "body": body,
        "commit": f"{change['commit']}\n\nFrom the catalog inbox ({inbox}#{number}).",
        "message": f"Pull Request für: {change['summary']}.{manual}",
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--issue", type=Path, required=True, help="the GitHub issue as JSON")
    parser.add_argument("--inbox", default=os.environ.get("GITHUB_REPOSITORY", "inbox"),
                        help="owner/name of the inbox repository, for the link")
    parser.add_argument("--data", type=Path, default=data_compiler.DATA)
    parser.add_argument("--resources", type=Path, default=data_compiler.RESOURCES)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    issue = json.loads(args.issue.read_text(encoding="utf-8"))
    result = run(issue, args.inbox, args.data, args.resources)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{result['status']}: {result['message']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
