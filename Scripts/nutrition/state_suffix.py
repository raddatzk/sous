#!/usr/bin/env python3
"""Splitting a BLS name into (base name, preparation state).

Lifted out of the old `merge_states.py` unchanged, because what it is *for*
changed while what it *does* did not. It used to decide which rows got averaged
into one entry; it now decides which SBLS code a kitchen word means in which
state - "Kartoffel" -> {raw: K110100, cooked: K110132}, two rows that stay two
rows. Nothing is merged and nothing is averaged any more (decision O2).
"""
from __future__ import annotations

import re

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
