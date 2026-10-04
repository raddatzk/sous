#!/usr/bin/env python3
"""Files shared catalog adjustments as issues in the private inbox repository.

Phase 10 of INGREDIENTS-DATA-PLAN.md, §3 D of INGREDIENTS-DATA.md. The app's
"Anpassungen teilen" writes `CatalogSubmission` records to the public CloudKit
database: one per share, its `items` field a JSON list in the wire format of
`CatalogSubmission.Item` (SousKit). Nobody but the role `Publisher` can read
them. Once a night the inbox repository's workflow runs this script, which

1. reads every submission with the server-to-server key (`cloudkit.py`),
2. keeps at most PER_CREATOR items per creator, oldest first, and drops the rest,
3. groups the items by the normalized name and files one issue per name —
   or, while one is open for that name, updates its block and comments,
4. deletes the records it filed (and the ones it dropped).

The creator id is used for the cap and nothing else: it is never written to an
issue. Every issue carries the accumulated reports as a machine-readable block
(```json sous-catalog```), which phase 10b turns into a data pull request.

Idempotent: the block lists the record names it already counts, so a night that
filed an issue but failed before deleting does not count a record twice.

    GITHUB_TOKEN=… GITHUB_REPOSITORY=owner/inbox \\
    CLOUDKIT_KEY_ID=… CLOUDKIT_PRIVATE_KEY="$(cat key.pem)" \\
        python3 Scripts/data/inbox.py --environment development [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cloudkit  # noqa: E402
from compile import normalize  # noqa: E402

SUBMISSION_TYPE = "CatalogSubmission"
#: The `schema` of the submissions this script reads; others are left alone.
SUBMISSION_SCHEMA = 1
#: The `schema` of the block in an issue.
BLOCK_SCHEMA = 1
#: At most this many items per creator and night; the rest is dropped.
PER_CREATOR = 200
#: A night reads at most this many records; the rest waits for the next.
MAX_RECORDS = 5000
#: How many lines and record names a block keeps.
MAX_LINES = 5
MAX_RECORD_NAMES = 500

LABEL = "katalog"
KIND_LABELS = {
    "countsAs": "zählt-wie",
    "word": "neu",
    "unknown": "neu",
    "values": "werte",
    "product": "produkt",
}
LABEL_COLORS = {"katalog": "0e8a16", "zählt-wie": "1d76db", "neu": "fbca04", "werte": "d93f0b", "produkt": "5319e7"}
STATES = ("unspecified", "raw", "cooked")
BLOCK = re.compile(r"```json sous-catalog\n(.*?)\n```", re.S)


# --------------------------------------------------------------------------
# Reading submissions

def _text(value: Any, limit: int) -> Optional[str]:
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] if value else None


def _number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value < 0 or value > 100000:
        return None
    return int(value) if float(value).is_integer() else round(float(value), 3)


def clean_item(raw: Any) -> Optional[Dict[str, Any]]:
    """An item as the app sends it, checked field by field: anything malformed
    is dropped, free text collapsed and capped. None if nothing usable is left."""
    if not isinstance(raw, dict) or raw.get("kind") not in KIND_LABELS:
        return None
    name = _text(raw.get("name"), 80)
    if not name:
        return None
    item: Dict[str, Any] = {"kind": raw["kind"], "name": name}
    if catalog_id := _text(raw.get("catalogID"), 80):
        item["catalogID"] = catalog_id
    target = raw.get("target")
    if isinstance(target, dict) and _text(target.get("id"), 80) and _text(target.get("name"), 80):
        item["target"] = {"id": _text(target["id"], 80), "name": _text(target["name"], 80)}
    values = raw.get("values")
    if isinstance(values, dict):
        cleaned = {k: _number(v) for k, v in values.items()
                   if isinstance(k, str) and re.fullmatch(r"[A-Za-z]{2,24}", k) and k != "absent"}
        cleaned = {k: v for k, v in cleaned.items() if v is not None}
        absent = values.get("absent")
        if isinstance(absent, list):
            listed = sorted({a for a in absent if isinstance(a, str) and re.fullmatch(r"[A-Za-z]{2,24}", a)})
            if listed:
                cleaned["absent"] = listed
        if "kcal" in cleaned:
            item["values"] = cleaned
            if source := _text(raw.get("source"), 200):
                item["source"] = source
    weights = raw.get("weights")
    if isinstance(weights, dict):
        cleaned_weights = {}
        for unit, weight in list(weights.items())[:20]:
            unit = _text(unit, 20)
            grams = _number(weight.get("grams")) if isinstance(weight, dict) else None
            if unit and grams:
                entry: Dict[str, Any] = {"grams": grams}
                if weight.get("state") in STATES and weight["state"] != "unspecified":
                    entry["state"] = weight["state"]
                cleaned_weights[unit] = entry
        if cleaned_weights:
            item["weights"] = cleaned_weights
    if brand := _text(raw.get("brand"), 80):
        item["brand"] = brand
    if (ean := _text(raw.get("ean"), 20)) and ean.isdigit():
        item["ean"] = ean
    recipes = raw.get("recipes")
    item["recipes"] = recipes if isinstance(recipes, int) and not isinstance(recipes, bool) and 0 <= recipes <= 10000 else 0
    if line := _text(raw.get("line"), 200):
        item["line"] = line
    return item


@dataclass
class Submission:
    record_name: str
    creator: str
    created: int
    app: Optional[str]
    data_version: Optional[int]
    items: List[Dict[str, Any]]
    #: False for a schema this script does not know: left for a newer script.
    readable: bool = True


def _field(record: Dict[str, Any], name: str) -> Any:
    return (record.get("fields", {}).get(name) or {}).get("value")


def read_submission(record: Dict[str, Any]) -> Submission:
    created = record.get("created") or {}
    submission = Submission(
        record_name=record["recordName"],
        creator=created.get("userRecordName") or "?",
        created=int(created.get("timestamp") or 0),
        app=_text(_field(record, "app"), 40),
        data_version=_field(record, "dataVersion") if isinstance(_field(record, "dataVersion"), int) else None,
        items=[],
    )
    if _field(record, "schema") != SUBMISSION_SCHEMA:
        submission.readable = False
        return submission
    try:
        raw_items = json.loads(_field(record, "items") or "[]")
    except ValueError:
        raw_items = []
    if isinstance(raw_items, list):
        submission.items = [item for item in map(clean_item, raw_items[:50]) if item]
    return submission


def fetch(client: "cloudkit.Client") -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    marker = None
    while len(records) < MAX_RECORDS:
        page, marker = client.query_page(SUBMISSION_TYPE, sort_by="___createTime", continuation=marker)
        records.extend(page)
        if not marker:
            break
    return records[:MAX_RECORDS]


def capped(submissions: Iterable[Submission]) -> Tuple[List[Submission], int]:
    """At most PER_CREATOR items per creator, oldest first; what was dropped."""
    taken: Dict[str, int] = {}
    kept, dropped = [], 0
    for submission in sorted(submissions, key=lambda s: (s.created, s.record_name)):
        room = max(PER_CREATOR - taken.get(submission.creator, 0), 0)
        dropped += max(len(submission.items) - room, 0)
        submission.items = submission.items[:room]
        taken[submission.creator] = taken.get(submission.creator, 0) + len(submission.items)
        kept.append(submission)
    return kept, dropped


# --------------------------------------------------------------------------
# The block

def answer_of(item: Dict[str, Any]) -> Dict[str, Any]:
    """What an item says, without where it occurs: what is counted alike."""
    return {k: v for k, v in item.items() if k not in ("name", "recipes", "line")}


def merge(block: Optional[Dict[str, Any]], name: str,
          reports: List[Tuple[Submission, Dict[str, Any]]]) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """The block with this night's reports for one name counted in, and the
    answers they brought. A report is one submission; a record already in the
    block is not counted again, and one creator counts once per night."""
    block = json.loads(json.dumps(block)) if block else {
        "schema": BLOCK_SCHEMA, "name": name, "normalized": normalize(name),
        "reports": 0, "recipes": 0, "lines": [], "answers": [], "apps": [], "dataVersions": [], "records": [],
    }
    seen_records = set(block["records"])
    seen_creators = set()
    new_answers: List[Dict[str, Any]] = []
    for submission, item in reports:
        if submission.record_name in seen_records or submission.creator in seen_creators:
            continue
        seen_creators.add(submission.creator)
        block["records"].append(submission.record_name)
        block["reports"] += 1
        block["recipes"] += item.get("recipes", 0)
        if (line := item.get("line")) and line not in block["lines"] and len(block["lines"]) < MAX_LINES:
            block["lines"].append(line)
        if submission.app and submission.app not in block["apps"]:
            block["apps"].append(submission.app)
        if submission.data_version and submission.data_version not in block["dataVersions"]:
            block["dataVersions"].append(submission.data_version)
        answer = answer_of(item)
        for known in block["answers"]:
            if {k: v for k, v in known.items() if k != "reports"} == answer:
                known["reports"] += 1
                break
        else:
            block["answers"].append({**answer, "reports": 1})
        new_answers.append(answer)
    block["records"] = block["records"][-MAX_RECORD_NAMES:]
    return block, new_answers


def read_block(body: str) -> Optional[Dict[str, Any]]:
    match = BLOCK.search(body or "")
    if not match:
        return None
    try:
        block = json.loads(match.group(1))
    except ValueError:
        return None
    return block if isinstance(block, dict) and block.get("schema") == BLOCK_SCHEMA else None


# --------------------------------------------------------------------------
# Writing issues

def _number_text(value: Any) -> str:
    return str(value).replace(".", ",")


def describe(answer: Dict[str, Any]) -> str:
    """One answer in the words of the app's sheet."""
    kind = answer["kind"]
    if kind == "countsAs":
        target = answer.get("target") or {}
        text = f"zählt wie {target.get('name', '?')} (`{target.get('id', '?')}`)"
    elif kind == "word":
        text = "eigenes Wort"
    elif kind == "values":
        text = f"eigene Angaben zu `{answer.get('catalogID', '?')}`"
    elif kind == "product":
        text = "Produkt"
        if answer.get("brand"):
            text += f", Marke {answer['brand']}"
        if answer.get("ean"):
            text += f", EAN {answer['ean']}"
        if answer.get("target"):
            text += f", rechnet wie {answer['target']['name']} (`{answer['target']['id']}`)"
    else:
        text = "unbekannt"
    if values := answer.get("values"):
        parts = [f"{_number_text(values['kcal'])} kcal"]
        for key, unit in (("proteinG", "g Eiweiß"), ("fatG", "g Fett"), ("carbsG", "g Kohlenhydrate")):
            if key in values:
                parts.append(f"{_number_text(values[key])} {unit}")
        text += " · " + ", ".join(parts) + " pro 100 g"
        if answer.get("source"):
            text += f" (Quelle: {answer['source']})"
    for unit, weight in sorted((answer.get("weights") or {}).items()):
        text += f" · 1 {unit} = {_number_text(weight['grams'])} g"
        if weight.get("state"):
            text += f" ({weight['state']})"
    return text


def title(block: Dict[str, Any]) -> str:
    first = block["answers"][0] if block["answers"] else {"kind": "unknown"}
    name = f"„{block['name']}“"
    kind = first["kind"]
    if kind == "countsAs":
        return f"{name} zählt wie {(first.get('target') or {}).get('name', '?')}"
    if kind == "product":
        return f"{name}: Produkt" + (f" ({first['brand']})" if first.get("brand") else "")
    return f"{name}: " + {"word": "neues Wort", "values": "eigene Angaben", "unknown": "unbekannt"}[kind]


def marker(normalized: str) -> str:
    return f"<!-- sous-catalog:{normalized} -->"


def body(block: Dict[str, Any]) -> str:
    lines = [
        marker(block["normalized"]),
        f"**Name:** „{block['name']}“  ",
        f"**Meldungen:** {block['reports']} · **in Rezepten:** {block['recipes']}",
        "",
        "| Angabe | Meldungen |",
        "|---|---|",
    ]
    for answer in block["answers"]:
        lines.append(f"| {describe(answer).replace('|', '/')} | {answer['reports']} |")
    if block["lines"]:
        lines += ["", "**Zeilen, wie geschrieben:**"] + [f"- „{line}“" for line in block["lines"]]
    lines += [
        "",
        f"Sous {', '.join(block['apps']) or '?'} · Daten {', '.join(map(str, block['dataVersions'])) or '?'}",
        "",
        "<details><summary>Für die Maschine</summary>",
        "",
        "```json sous-catalog",
        json.dumps(block, ensure_ascii=False, sort_keys=True, indent=1),
        "```",
        "",
        "</details>",
    ]
    return "\n".join(lines) + "\n"


def labels(block: Dict[str, Any]) -> List[str]:
    return [LABEL] + sorted({KIND_LABELS[a["kind"]] for a in block["answers"]})


class GitHub:
    """The few issue calls the inbox needs, with the workflow's own token."""

    def __init__(self, repository: str, token: str, api: str = "https://api.github.com"):
        self.repository = repository
        self.token = token
        self.api = api

    def _call(self, method: str, path: str, payload: Any = None) -> Any:
        request = urllib.request.Request(
            f"{self.api}/repos/{self.repository}{path}",
            data=None if payload is None else json.dumps(payload).encode(),
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def open_issues(self) -> List[Dict[str, Any]]:
        issues, page = [], 1
        while True:
            batch = self._call("GET", f"/issues?state=open&labels={LABEL}&per_page=100&page={page}")
            issues += [i for i in batch if "pull_request" not in i]
            if len(batch) < 100:
                return issues
            page += 1

    def ensure_labels(self) -> None:
        for name, color in LABEL_COLORS.items():
            try:
                self._call("POST", "/labels", {"name": name, "color": color})
            except urllib.error.HTTPError as error:
                if error.code != 422:  # exists already
                    raise

    def create(self, title: str, body: str, labels: List[str]) -> Dict[str, Any]:
        return self._call("POST", "/issues", {"title": title, "body": body, "labels": labels})

    def update(self, number: int, body: str, labels: List[str]) -> None:
        self._call("PATCH", f"/issues/{number}", {"body": body})
        self._call("POST", f"/issues/{number}/labels", {"labels": labels})

    def comment(self, number: int, text: str) -> None:
        self._call("POST", f"/issues/{number}/comments", {"body": text})


# --------------------------------------------------------------------------
# A night

@dataclass
class Night:
    filed: List[str] = field(default_factory=list)
    updated: List[str] = field(default_factory=list)
    deleted: List[str] = field(default_factory=list)
    kept: List[str] = field(default_factory=list)
    dropped_items: int = 0
    failures: List[str] = field(default_factory=list)


def run(client: Any, github: Any, dry_run: bool = False, out=sys.stdout) -> Night:
    night = Night()
    submissions = [read_submission(r) for r in fetch(client)]
    unreadable = [s for s in submissions if not s.readable]
    night.kept += [s.record_name for s in unreadable]
    submissions, night.dropped_items = capped(s for s in submissions if s.readable)

    by_name: Dict[str, List[Tuple[Submission, Dict[str, Any]]]] = {}
    names: Dict[str, str] = {}
    for submission in submissions:
        for item in submission.items:
            key = normalize(item["name"])
            by_name.setdefault(key, []).append((submission, item))
            names.setdefault(key, item["name"])

    open_issues: Dict[str, Dict[str, Any]] = {}
    if by_name:
        if not dry_run:
            github.ensure_labels()
        for issue in github.open_issues():
            block = read_block(issue.get("body") or "")
            if block and block.get("normalized"):
                open_issues.setdefault(block["normalized"], {**issue, "block": block})

    failed_records = set()
    for key in sorted(by_name):
        issue = open_issues.get(key)
        block, new_answers = merge(issue["block"] if issue else None, names[key], by_name[key])
        if not new_answers:
            continue
        try:
            if dry_run:
                print(f"--- {'update #' + str(issue['number']) if issue else 'new'}: {title(block)}\n{body(block)}", file=out)
            elif issue:
                github.update(issue["number"], body(block), labels(block))
                github.comment(issue["number"], f"{len(new_answers)} neue Meldung(en):\n"
                               + "\n".join(f"- {describe(a)}" for a in new_answers))
                night.updated.append(key)
            else:
                github.create(title(block), body(block), labels(block))
                night.filed.append(key)
        except Exception as error:  # one name failing must not lose the others
            night.failures.append(f"{key}: {error}")
            failed_records.update(s.record_name for s, _ in by_name[key])

    done = [s.record_name for s in submissions if s.record_name not in failed_records]
    night.kept += sorted(failed_records)
    if not dry_run and done:
        client.delete(done)
        night.deleted = done
    print(f"{len(submissions)} submissions · {len(night.filed)} issues filed · {len(night.updated)} updated · "
          f"{len(night.deleted)} records deleted · {night.dropped_items} items over the cap dropped · "
          f"{len(night.kept)} records kept", file=out)
    for failure in night.failures:
        print(f"failed: {failure}", file=out)
    return night


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--environment", choices=cloudkit.ENVIRONMENTS, required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"),
                        help="owner/name of the private inbox repository")
    parser.add_argument("--dry-run", action="store_true", help="print the issues; write and delete nothing")
    args = parser.parse_args(argv)
    if not args.repository:
        parser.error("--repository or GITHUB_REPOSITORY is needed")
    token = os.environ.get("GITHUB_TOKEN")
    if not token and not args.dry_run:
        parser.error("GITHUB_TOKEN is needed")
    client = cloudkit.Client.from_environment(args.environment)
    night = run(client, GitHub(args.repository, token or ""), dry_run=args.dry_run)
    return 1 if night.failures else 0


if __name__ == "__main__":
    sys.exit(main())
