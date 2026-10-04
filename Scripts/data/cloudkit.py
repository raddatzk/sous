"""A minimal CloudKit Web Services client for the public database.

Requests are signed with a server-to-server key, which acts as the developer who
created it and reaches only the public database. The key id and the PEM-encoded
private key (EC P-256) come from the environment:

    CLOUDKIT_KEY_ID           the key id shown in the CloudKit Console
    CLOUDKIT_PRIVATE_KEY      the PEM text, or
    CLOUDKIT_PRIVATE_KEY_FILE a path to it

Only the standard library and `cryptography` are used.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

CONTAINER = "iCloud.me.raddatz.sous"
HOST = "https://api.apple-cloudkit.com"
ENVIRONMENTS = ("development", "production")


class CloudKitError(Exception):
    """A request CloudKit refused, with its server error code when it gave one."""

    def __init__(self, status: int, code: Optional[str], reason: str, body: Any = None):
        super().__init__(f"{status} {code or ''} {reason}".strip())
        self.status = status
        self.code = code
        self.reason = reason
        self.body = body


class Client:
    def __init__(self, environment: str, key_id: str, private_key_pem: bytes,
                 container: str = CONTAINER):
        if environment not in ENVIRONMENTS:
            raise ValueError(f"unknown environment {environment!r}")
        self.environment = environment
        self.container = container
        self.key_id = key_id
        self._key = serialization.load_pem_private_key(private_key_pem, password=None)
        if not isinstance(self._key, ec.EllipticCurvePrivateKey):
            raise ValueError("the server-to-server key must be an EC (P-256) key")

    @classmethod
    def from_environment(cls, environment: str) -> "Client":
        key_id = os.environ.get("CLOUDKIT_KEY_ID")
        pem = os.environ.get("CLOUDKIT_PRIVATE_KEY")
        path = os.environ.get("CLOUDKIT_PRIVATE_KEY_FILE")
        if not key_id or not (pem or path):
            raise SystemExit("CLOUDKIT_KEY_ID and CLOUDKIT_PRIVATE_KEY(_FILE) must be set")
        data = pem.encode() if pem else open(path, "rb").read()
        return cls(environment, key_id, data)

    # -- transport ------------------------------------------------------------

    def _subpath(self, operation: str) -> str:
        return f"/database/1/{self.container}/{self.environment}/public/{operation}"

    def request(self, operation: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Sends one signed request; `payload` None means GET."""
        subpath = self._subpath(operation)
        body = b"" if payload is None else json.dumps(payload, separators=(",", ":")).encode()
        date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        body_hash = base64.b64encode(hashlib.sha256(body).digest()).decode()
        message = f"{date}:{body_hash}:{subpath}".encode()
        signature = base64.b64encode(self._key.sign(message, ec.ECDSA(hashes.SHA256()))).decode()
        request = urllib.request.Request(
            HOST + subpath,
            data=body if payload is not None else None,
            method="GET" if payload is None else "POST",
            headers={
                "Content-Type": "application/json",
                "X-Apple-CloudKit-Request-KeyID": self.key_id,
                "X-Apple-CloudKit-Request-ISO8601Date": date,
                "X-Apple-CloudKit-Request-SignatureV1": signature,
            },
        )
        return _send(request)

    # -- operations -----------------------------------------------------------

    def caller(self) -> Dict[str, Any]:
        """The user record the key acts as."""
        return self.request("users/caller")

    def lookup(self, names: List[str], desired_keys: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        payload: Dict[str, Any] = {"records": [{"recordName": n} for n in names]}
        if desired_keys is not None:
            payload["desiredKeys"] = desired_keys
        return self.request("records/lookup", payload)["records"]

    def modify(self, operations: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Applies the operations; a per-record failure is raised, not returned.

        The public default zone does not do atomic batches, so a release and the
        pointer that names it are written in two requests, release first.
        """
        records = self.request("records/modify", {"operations": operations, "atomic": False})["records"]
        for record in records:
            if "serverErrorCode" in record:
                raise CloudKitError(200, record["serverErrorCode"], record.get("reason", ""), record)
        return records

    def query(self, record_type: str, desired_keys: Optional[List[str]] = None,
              limit: int = 200) -> List[Dict[str, Any]]:
        payload: Dict[str, Any] = {"query": {"recordType": record_type}, "resultsLimit": limit}
        if desired_keys is not None:
            payload["desiredKeys"] = desired_keys
        return self.request("records/query", payload)["records"]

    def query_page(self, record_type: str, desired_keys: Optional[List[str]] = None,
                   limit: int = 200, sort_by: Optional[str] = None,
                   continuation: Optional[str] = None) -> Tuple[List[Dict[str, Any]], Optional[str]]:
        """One page of a query, oldest first when `sort_by` names a time field,
        and the marker for the next page (None after the last)."""
        query: Dict[str, Any] = {"recordType": record_type}
        if sort_by:
            query["sortBy"] = [{"fieldName": sort_by, "ascending": True}]
        payload: Dict[str, Any] = {"query": query, "resultsLimit": limit}
        if desired_keys is not None:
            payload["desiredKeys"] = desired_keys
        if continuation:
            payload["continuationMarker"] = continuation
        response = self.request("records/query", payload)
        return response.get("records", []), response.get("continuationMarker")

    def delete(self, names: List[str]) -> None:
        """Deletes the records, whatever their change tag; a name already gone
        is not an error."""
        for start in range(0, len(names), 200):
            batch = names[start:start + 200]
            records = self.request("records/modify", {"atomic": False, "operations": [
                {"operationType": "forceDelete", "record": {"recordName": name}} for name in batch]})["records"]
            for record in records:
                if record.get("serverErrorCode") not in (None, "NOT_FOUND"):
                    raise CloudKitError(200, record["serverErrorCode"], record.get("reason", ""), record)

    def upload_asset(self, record_type: str, field: str, record_name: str, data: bytes) -> Dict[str, Any]:
        """Uploads one file and returns the asset dictionary for a field value."""
        tokens = self.request("assets/upload", {"tokens": [
            {"recordType": record_type, "fieldName": field, "recordName": record_name}]})["tokens"]
        upload = urllib.request.Request(tokens[0]["url"], data=data, method="POST",
                                        headers={"Content-Type": "application/octet-stream"})
        return _send(upload)["singleFile"]


def _send(request: urllib.request.Request) -> Dict[str, Any]:
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw.decode(errors="replace")
        code = body.get("serverErrorCode") if isinstance(body, dict) else None
        reason = body.get("reason", "") if isinstance(body, dict) else str(body)
        raise CloudKitError(error.code, code, reason, body) from None
    return json.loads(raw) if raw else {}
