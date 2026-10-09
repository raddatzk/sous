"""Tests for approve.py: labels to a change of Community/, compiled, or refused.

    python3 -m unittest discover -s Scripts/data -p 'test_*.py'
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import approve  # noqa: E402
import compile as data_compiler  # noqa: E402
import inbox  # noqa: E402


def issue(name, answers, labels, number=7):
    block = {"schema": 1, "name": name, "normalized": inbox.normalize(name), "reports": 2, "recipes": 3,
             "lines": [f"1 EL {name}"], "answers": answers, "apps": [], "dataVersions": [], "records": []}
    return {"number": number, "title": name, "labels": [{"name": n} for n in labels],
            "body": inbox.body(block)}


def counts_as(target_id, target_name, reports=1, **extra):
    return {"kind": "countsAs", "target": {"id": target_id, "name": target_name}, "reports": reports, **extra}


class ApproveTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.data = self.root / "Community"
        self.resources = self.root / "Resources"
        shutil.copytree(data_compiler.DATA, self.data)
        shutil.copytree(data_compiler.RESOURCES, self.resources)

    def tearDown(self):
        shutil.rmtree(self.root)

    def run_issue(self, item):
        return approve.run(item, "owner/inbox", self.data, self.resources)

    def compiled(self):
        outputs, _, released = data_compiler.compile_data(self.data, self.resources)
        return {name: json.loads(text) for name, text in outputs.items()}, released

    # -- the mechanical cases ----------------------------------------------

    def test_an_alias_joins_the_target_and_compiles(self):
        result = self.run_issue(issue("Kokosnussmilch", [counts_as("kokosmilch", "Kokosmilch", 2)], ["als-alias"]))
        self.assertEqual(result["status"], "changed", result["message"])
        self.assertEqual(result["branch"], "inbox/7-kokosnussmilch")
        self.assertIn("„Kokosnussmilch“ als Schreibweise von Kokosmilch", result["title"])
        self.assertIn("owner/inbox#7", result["body"])
        self.assertNotIn("1 EL", result["body"])  # no line of a household's recipe
        self.assertNotIn("Hinweise von compile.py", result["body"])  # main's own warnings stay out
        text = (self.data / "ingredients/kokosmilch.yaml").read_text(encoding="utf-8")
        self.assertIn("    - Kokosnussmilch\n", text)
        words = {w["name"]: w for w in json.loads((self.resources / "kitchen_words.json").read_text())}
        self.assertIn("Kokosnussmilch", words["Kokosmilch"]["aliases"])
        # What was written is exactly what compile.py would write again.
        outputs, released = self.compiled()
        self.assertEqual((self.data / "released-ids.txt").read_text(encoding="utf-8"), released)

    def test_a_variety_gets_its_own_id_under_the_target(self):
        result = self.run_issue(issue("Räuchertofu natur", [counts_as("tofu", "Tofu")], ["als-sorte"]))
        self.assertEqual(result["status"], "changed", result["message"])
        text = (self.data / "ingredients/tofu.yaml").read_text(encoding="utf-8")
        self.assertIn("    - id: raeuchertofu-natur\n      name: Räuchertofu natur\n", text)
        self.assertIn("raeuchertofu-natur", (self.data / "released-ids.txt").read_text(encoding="utf-8"))

    def test_a_new_word_needs_its_category_and_has_no_values(self):
        waiting = self.run_issue(issue("Trollpaste", [{"kind": "unknown", "reports": 1}], ["kat:gewürze"]))
        self.assertEqual(waiting["status"], "waiting")
        missing = self.run_issue(issue("Trollpaste", [{"kind": "unknown", "reports": 1}], ["neues-wort"]))
        self.assertEqual(missing["status"], "refused")
        self.assertIn("kat:", missing["message"])

        result = self.run_issue(issue("Trollpaste", [{"kind": "unknown", "reports": 1}], ["neues-wort", "kat:gewürze"]))
        self.assertEqual(result["status"], "changed", result["message"])
        self.assertEqual(
            (self.data / "ingredients/trollpaste.yaml").read_text(encoding="utf-8"),
            "- id: trollpaste\n  name: Trollpaste\n  category: spices\n  nutrition: without\n"
            f"  via: {approve.WORD_VIA}\n")
        self.assertGreater(len(approve.WORD_VIA), 20)  # BundledDataTests wants a reason
        curation = json.loads((self.resources / "curation.json").read_text(encoding="utf-8"))
        self.assertIn("Trollpaste", json.dumps(curation, ensure_ascii=False))

    def test_values_are_left_for_the_curator(self):
        answer = counts_as("kokosmilch", "Kokosmilch", values={"kcal": 90}, source="Dose",
                           weights={"Dose": {"grams": 240}})
        result = self.run_issue(issue("Kokosnussmilch", [answer], ["als-alias"]))
        self.assertEqual(result["status"], "changed")
        self.assertIn("Nicht mechanisch, bitte von Hand", result["message"])
        self.assertIn("90 kcal", result["message"])
        self.assertNotIn("240", (self.data / "ingredients/kokosmilch.yaml").read_text(encoding="utf-8"))

    # -- refusals, and nothing written -------------------------------------

    def assertRefused(self, item, fragment):
        before = {p: p.read_bytes() for p in list(self.data.rglob("*")) + list(self.resources.rglob("*")) if p.is_file()}
        result = self.run_issue(item)
        self.assertEqual(result["status"], "refused", result)
        self.assertIn(fragment, result["message"])
        after = {p: p.read_bytes() for p in list(self.data.rglob("*")) + list(self.resources.rglob("*")) if p.is_file()}
        self.assertEqual(before, after)

    def test_a_known_name_is_refused(self):
        self.assertRefused(issue("Tofu", [counts_as("tempeh", "Tempeh")], ["als-alias"]), "kennt der Katalog schon")

    def test_reports_that_disagree_are_refused(self):
        self.assertRefused(issue("Nussmilch", [counts_as("kokosmilch", "Kokosmilch"), counts_as("tofu", "Tofu")],
                                 ["als-alias"]), "uneins")

    def test_no_target_no_alias(self):
        self.assertRefused(issue("Trollpaste", [{"kind": "unknown", "reports": 1}], ["als-sorte"]), "kein Wort")

    def test_two_approvals_at_once_are_refused(self):
        self.assertRefused(issue("Kokosnussmilch", [counts_as("kokosmilch", "Kokosmilch")], ["als-alias", "als-sorte"]),
                           "Mehrere Freigaben")

    def test_a_file_that_does_not_round_trip_is_left_alone(self):
        # Every shipped file round-trips (RoundTripTests), so the comment that
        # would be lost is written into this copy.
        path = self.data / "ingredients/knoblauch.yaml"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "    - Knoblauchzehe: {unit: Zehe}\n",
            "    - Knoblauchzehe: {unit: Zehe}   # \"2 Knoblauchzehen\" = 2 Zehen Knoblauch\n", 1),
            encoding="utf-8")
        self.assertRefused(issue("Knofi", [counts_as("knoblauch", "Knoblauch")], ["als-alias"]), "verlustfrei")

    def test_a_name_with_a_comma_is_refused(self):
        self.assertRefused(issue("Tomate, passiert", [counts_as("tomate", "Tomate")], ["als-sorte"]), "Komma")

    def test_an_unknown_category_is_refused(self):
        self.assertRefused(issue("Trollpaste", [{"kind": "unknown", "reports": 1}], ["neues-wort", "kat:unbekannt"]),
                           "Unbekannte Kategorie")

    def test_a_change_that_does_not_compile_is_rolled_back(self):
        # compile.py allows letters, digits, space and - ' % / . , in a spelling.
        self.assertRefused(issue("Kokosmilch!", [counts_as("kokosmilch", "Kokosmilch")], ["als-alias"]),
                           "So kompiliert der Katalog nicht")


class RoundTripTests(unittest.TestCase):
    def test_every_ingredient_file_writes_back_byte_for_byte(self):
        differing = [p.name for p in sorted((data_compiler.DATA / "ingredients").glob("*.yaml"))
                     if approve.dump(approve.yaml.safe_load(p.read_text(encoding="utf-8")))
                     != p.read_text(encoding="utf-8")]
        self.assertEqual(differing, [])


if __name__ == "__main__":
    unittest.main()
