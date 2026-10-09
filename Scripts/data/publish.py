#!/usr/bin/env python3
"""Publish the compiled data set to the app's CloudKit public database.

    python3 Scripts/data/publish.py --environment development [--commit SHA]
    python3 Scripts/data/publish.py --environment development --point-to 2026100100

Publishes exactly what the app bundles: the files and the manifest under
SousKit/Sources/SousKit/Resources. It holds them against Community/ itself first —
`compile.py --check` — and publishes nothing when they differ: a push to main
publishes as far as production, so a push that skipped the
compiler must not get through. In two steps (INGREDIENTS-DATA §5):

1. a `DataRelease` record `release-<dataVersion>`, one asset per file in a
   field named after it, each read back and checked against the manifest
2. only then the pointer `current-v<schema>`, which the app reads daily

Releases are never deleted. A release already published is not published
again, and a run whose release exists but whose pointer moved on only checks
it. `--point-to` turns the pointer to an older release, as an emergency stop
for devices that have not fetched the newer one yet; devices that have keep
it, since a client never goes back. The real undo is a revert in Community/, which
compiles to a new, higher version.

The key is a server-to-server key of the environment, which acts as the
publisher's user record; that record holds the role `Publisher`, the only one
allowed to write these types. See `cloudkit.py` for the variables it reads.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import sys
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cloudkit  # noqa: E402
import compile as data_compiler  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
RESOURCES = REPO_ROOT / "SousKit/Sources/SousKit/Resources"
MANIFEST = "manifest.json"
RELEASE_TYPE = "DataRelease"
POINTER_TYPE = "CurrentRelease"


def field_for(file_name: str) -> str:
    """`kitchen_words.json` → `kitchen_words`, as the app reads it."""
    return file_name.rsplit(".", 1)[0]


def release_name(version: int) -> str:
    return f"release-{version}"


def pointer_name(schema: int) -> str:
    return f"current-v{schema}"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_set(resources: Path) -> tuple[Dict[str, Any], bytes, Dict[str, bytes]]:
    manifest_bytes = (resources / MANIFEST).read_bytes()
    manifest = json.loads(manifest_bytes)
    files: Dict[str, bytes] = {}
    for name, digest in sorted(manifest["files"].items()):
        data = (resources / name).read_bytes()
        if sha256(data) != digest:
            raise SystemExit(f"{name} does not match the manifest; run compile.py first")
        files[name] = data
    return manifest, manifest_bytes, files


def value(record: Dict[str, Any], field: str) -> Any:
    return record.get("fields", {}).get(field, {}).get("value")


def check_release(client: cloudkit.Client, name: str, manifest: Dict[str, Any]) -> None:
    """Reads the release back and checks every asset's bytes against the manifest."""
    record = client.lookup([name])[0]
    if "serverErrorCode" in record:
        raise SystemExit(f"{name} cannot be read back: {record['serverErrorCode']}")
    if record.get("recordType") != RELEASE_TYPE:
        raise SystemExit(f"{name} is a {record.get('recordType')}, not a {RELEASE_TYPE}")
    if value(record, "dataVersion") != manifest["dataVersion"] or value(record, "sha256") != manifest["sha256"]:
        raise SystemExit(f"{name} holds another set than the manifest names")
    for file_name, digest in manifest["files"].items():
        asset = value(record, field_for(file_name))
        if not asset or "downloadURL" not in asset:
            raise SystemExit(f"{name} lacks {file_name}")
        url = asset["downloadURL"].replace("${f}", file_name)
        with urllib.request.urlopen(url, timeout=120) as response:
            if sha256(response.read()) != digest:
                raise SystemExit(f"{name}: {file_name} came back with other bytes")
    print(f"  checked {name}: {len(manifest['files'])} files match the manifest")


def publish_release(client: cloudkit.Client, manifest: Dict[str, Any], manifest_bytes: bytes,
                    files: Dict[str, bytes], commit: Optional[str], published: int) -> str:
    name = release_name(manifest["dataVersion"])
    existing = client.lookup([name], desired_keys=["sha256"])[0]
    if "serverErrorCode" not in existing:
        if value(existing, "sha256") != manifest["sha256"]:
            raise SystemExit(f"{name} exists with another set; a version is never reused")
        print(f"  {name} exists already")
        return name
    if existing["serverErrorCode"] != "NOT_FOUND":
        raise SystemExit(f"{name}: {existing['serverErrorCode']} {existing.get('reason', '')}")

    fields: Dict[str, Any] = {
        "schema": {"value": manifest["schema"]},
        "dataVersion": {"value": manifest["dataVersion"]},
        "sha256": {"value": manifest["sha256"]},
        "manifest": {"value": manifest_bytes.decode()},
        "published": {"value": published},
    }
    if commit:
        fields["commit"] = {"value": commit}
    for file_name, data in files.items():
        field = field_for(file_name)
        fields[field] = {"value": client.upload_asset(RELEASE_TYPE, field, name, data)}
        print(f"  uploaded {file_name} ({len(data)} bytes)")
    client.modify([{"operationType": "create",
                    "record": {"recordType": RELEASE_TYPE, "recordName": name, "fields": fields}}])
    print(f"  created {name}")
    return name


def point(client: cloudkit.Client, manifest: Dict[str, Any], manifest_bytes: bytes, release: str,
          commit: Optional[str], published: int) -> None:
    name = pointer_name(manifest["schema"])
    current = client.lookup([name], desired_keys=["dataVersion"])[0]
    if "serverErrorCode" in current and current["serverErrorCode"] != "NOT_FOUND":
        raise SystemExit(f"{name}: {current['serverErrorCode']} {current.get('reason', '')}")
    if "serverErrorCode" not in current and current.get("recordType") != POINTER_TYPE:
        raise SystemExit(f"{name} is taken by a {current.get('recordType')}; delete it in the console")
    fields: Dict[str, Any] = {
        "schema": {"value": manifest["schema"]},
        "dataVersion": {"value": manifest["dataVersion"]},
        "sha256": {"value": manifest["sha256"]},
        "manifest": {"value": manifest_bytes.decode()},
        "release": {"value": {"recordName": release, "action": "NONE"}},
        "published": {"value": published},
    }
    if commit:
        fields["commit"] = {"value": commit}
    client.modify([{"operationType": "forceReplace",
                    "record": {"recordType": POINTER_TYPE, "recordName": name, "fields": fields}}])
    before = value(current, "dataVersion") if "serverErrorCode" not in current else None
    print(f"  {name}: {before} → {manifest['dataVersion']}")


def pointed_version(client: cloudkit.Client, schema: int) -> Optional[int]:
    record = client.lookup([pointer_name(schema)], desired_keys=["dataVersion"])[0]
    return None if "serverErrorCode" in record else value(record, "dataVersion")


def compile_check() -> list:
    """What `compile.py --check` would call stale: resources, or the
    released ids, that differ from compiling Community/ now."""
    try:
        outputs, _, released = data_compiler.compile_data(data_compiler.DATA, RESOURCES)
    except data_compiler.DataError as error:
        raise SystemExit(f"Community/ does not compile, nothing published:\n{error}")
    stale = [name for name, text in outputs.items()
             if not (RESOURCES / name).exists() or (RESOURCES / name).read_text(encoding="utf-8") != text]
    released_path = data_compiler.DATA / "released-ids.txt"
    if not released_path.exists() or released_path.read_text(encoding="utf-8") != released:
        stale.append("Community/released-ids.txt")
    return stale


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--environment", choices=cloudkit.ENVIRONMENTS, required=True)
    parser.add_argument("--resources", type=Path, default=RESOURCES)
    parser.add_argument("--commit", help="the Git commit the set was compiled from")
    parser.add_argument("--point-to", type=int, metavar="VERSION",
                        help="turn the pointer to this published release instead of publishing")
    args = parser.parse_args()

    client = cloudkit.Client.from_environment(args.environment)
    published = int(datetime.datetime.now(datetime.timezone.utc).timestamp() * 1000)
    print(f"CloudKit {args.environment}, acting as {client.caller()['userRecordName']}")

    if args.point_to:
        record = client.lookup([release_name(args.point_to)], desired_keys=["manifest", "commit"])[0]
        if "serverErrorCode" in record:
            raise SystemExit(f"{release_name(args.point_to)}: {record['serverErrorCode']}")
        manifest_text = value(record, "manifest")
        manifest = json.loads(manifest_text)
        check_release(client, release_name(args.point_to), manifest)
        point(client, manifest, manifest_text.encode(), release_name(args.point_to),
              value(record, "commit"), published)
        return

    if args.resources == RESOURCES:
        stale = compile_check()
        if stale:
            raise SystemExit("The resources differ from compile(Community/): " + ", ".join(stale)
                             + ". Nothing published; run Scripts/data/compile.py and commit.")
    manifest, manifest_bytes, files = load_set(args.resources)
    print(f"Data set {manifest['dataVersion']} (schema {manifest['schema']}, {len(files)} files)")
    current = pointed_version(client, manifest["schema"])
    release = publish_release(client, manifest, manifest_bytes, files, args.commit, published)
    check_release(client, release, manifest)
    if current is not None and current >= manifest["dataVersion"]:
        print(f"  {pointer_name(manifest['schema'])} is at {current} already; left alone")
        return
    point(client, manifest, manifest_bytes, release, args.commit, published)


if __name__ == "__main__":
    main()
