"""Tests for compile.py: the real Data/ compiles to the resources, and a
broken copy of it fails with a message that says what is wrong and where.

    python3 -m unittest discover -s Scripts/data -p 'test_*.py'
"""
from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import compile as data_compiler

# The rename SousKit's CatalogIDTests read, as this compiler writes it.
SWIFT_FIXTURE = data_compiler.REPO_ROOT / "SousKit/Tests/SousKitTests/Fixtures/Renames"


class Normalization(unittest.TestCase):
    """The vectors SousKit's NormalizationTests read too."""

    vectors = json.loads((data_compiler.DATA / "normalize-cases.json").read_text(encoding="utf-8"))

    def test_cases(self):
        for case in self.vectors["cases"]:
            with self.subTest(input=case["input"]):
                self.assertEqual(data_compiler.normalize(case["input"]), case["key"])

    def test_distinct(self):
        for a, b in self.vectors["distinct"]:
            with self.subTest(pair=(a, b)):
                self.assertNotEqual(data_compiler.normalize(a), data_compiler.normalize(b))


class BrokenData(unittest.TestCase):
    """Each test copies Data/, breaks one thing, and expects one message."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.data = self.tmp / "Data"
        shutil.copytree(data_compiler.DATA, self.data)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write(self, relative: str, text: str) -> None:
        (self.data / relative).write_text(text, encoding="utf-8")

    def edit(self, relative: str, old: str, new: str) -> None:
        path = self.data / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def assertFails(self, *fragments: str) -> None:
        with self.assertRaises(data_compiler.DataError) as caught:
            data_compiler.compile_data(self.data)
        for fragment in fragments:
            self.assertIn(fragment, str(caught.exception))

    def merge_zwetschge_into_pflaume(self) -> None:
        """A merge as a curator writes it: the absorbed entry's file goes,
        its spellings join the survivor, and its id moves under `formerly`."""
        (self.data / "ingredients/zwetschge.yaml").unlink()
        self.edit("ingredients/pflaume.yaml", "    - Pflaumen\n",
                  "    - Pflaumen\n    - Zwetschge\n  formerly: [zwetschge]\n")

    def test_the_real_data_compiles(self):
        outputs, _, released = data_compiler.compile_data(self.data)
        self.assertEqual(set(outputs), {
            "kitchen_words.json", "curation.json", "measures.json",
            "aisles.json", "community.json", "sources.json", "ids.json",
        })
        self.assertEqual(released, (self.data / "released-ids.txt").read_text(encoding="utf-8"))

    def test_every_word_carries_its_id(self):
        outputs, _, _ = data_compiler.compile_data(self.data)
        words = json.loads(outputs["kitchen_words.json"])
        by_name = {word["name"]: word for word in words}
        self.assertEqual(by_name["Rote Zwiebel"]["id"], "rote-zwiebel")
        self.assertTrue(all(word.get("id") for word in words))

    def test_a_merge_compiles_to_the_rename_map(self):
        self.merge_zwetschge_into_pflaume()
        outputs, _, released = data_compiler.compile_data(self.data)
        self.assertEqual(json.loads(outputs["ids.json"]),
                         {"renamed": {"zwetschge": "pflaume"}, "retired": []})
        self.assertIn("\nzwetschge\n", released)

    def test_the_swift_fixture_is_what_the_merge_compiles_to(self):
        self.merge_zwetschge_into_pflaume()
        outputs, _, _ = data_compiler.compile_data(self.data)
        fixture_ids = json.loads((SWIFT_FIXTURE / "ids.json").read_text(encoding="utf-8"))
        self.assertEqual(json.loads(outputs["ids.json"]), fixture_ids)
        compiled = {word["id"]: word for word in json.loads(outputs["kitchen_words.json"])}
        for word in json.loads((SWIFT_FIXTURE / "kitchen_words.json").read_text(encoding="utf-8")):
            with self.subTest(id=word["id"]):
                self.assertEqual(compiled[word["id"]]["name"], word["name"])
                self.assertEqual(compiled[word["id"]].get("parent"), word.get("parent"))
                self.assertLessEqual(set(word["aliases"]), set(compiled[word["id"]]["aliases"]))

    def test_a_released_id_that_vanishes(self):
        (self.data / "ingredients/zwetschge.yaml").unlink()
        self.assertFails("the id 'zwetschge' was released and no entry has it any more",
                         "under `formerly:` on the entry that absorbed it",
                         "Data/retired.yaml")

    def test_a_variety_whose_id_changes_without_formerly(self):
        self.edit("ingredients/zwiebel.yaml", "- id: rote-zwiebel", "- id: zwiebel-rot")
        self.assertFails("the id 'rote-zwiebel' was released and no entry has it any more")

    def test_a_retired_id(self):
        (self.data / "ingredients/zwetschge.yaml").unlink()
        self.write("retired.yaml", "- id: zwetschge\n  reason: Nur ein Test.\n")
        outputs, _, _ = data_compiler.compile_data(self.data)
        self.assertEqual(json.loads(outputs["ids.json"]),
                         {"renamed": {}, "retired": ["zwetschge"]})

    def test_an_absorbed_id_used_again(self):
        self.merge_zwetschge_into_pflaume()
        self.write("ingredients/zwetschge.yaml",
                   "- id: zwetschge\n  name: Hauszwetschge\n  category: fruit\n"
                   "  nutrition: without\n")
        self.assertFails("Pflaume lists 'zwetschge' under formerly, but Hauszwetschge in ",
                         "ingredients/zwetschge.yaml still has that id; an id is never reused")

    def test_a_retired_id_used_again(self):
        self.write("retired.yaml", "- id: zwetschge\n  reason: Nur ein Test.\n")
        self.assertFails("Data/retired.yaml: 'zwetschge' is retired, but Zwetschge in ",
                         "ingredients/zwetschge.yaml still has that id; an id is never reused")

    def test_an_id_absorbed_twice(self):
        self.merge_zwetschge_into_pflaume()
        self.edit("ingredients/zwiebel.yaml", "    - Speisezwiebel\n",
                  "    - Speisezwiebel\n  formerly: [zwetschge]\n")
        self.assertFails("'zwetschge' is listed under formerly by both")

    def test_formerly_an_id_nobody_released(self):
        self.edit("ingredients/pflaume.yaml", "    - Pflaumen\n",
                  "    - Pflaumen\n  formerly: [eierpflaume]\n")
        self.assertFails("Pflaume lists 'eierpflaume' under formerly, which was never released")

    def test_released_ids_only_grow(self):
        before = "# header\napfel\nbirne\n"
        self.assertEqual(data_compiler.lost_ids(before, "apfel\nbirne\nkiwi\n"), [])
        self.assertEqual(data_compiler.lost_ids(before, "apfel\n"), ["birne"])

    def test_a_new_inline_row_takes_a_numbered_code(self):
        self.edit("ingredients/zwetschge.yaml",
                  "  nutrition:\n    cooked: [F223152]\n    raw: [F223100]\n",
                  "  nutrition:\n    unspecified:\n      - code: Z000003\n"
                  "        name: Zwetschge\n        source: Test\n"
                  "        per100g: {kcal: '50'}\n")
        self.assertFails("Zwetschge's inline code Z000003 is not derived from its id; "
                         "write Z-zwetschge")

    def test_an_inline_row_named_after_its_entry(self):
        self.edit("ingredients/zwetschge.yaml",
                  "  nutrition:\n    cooked: [F223152]\n    raw: [F223100]\n",
                  "  nutrition:\n    unspecified:\n      - code: Z-zwetschge\n"
                  "        name: Zwetschge\n        source: Test\n"
                  "        per100g: {kcal: '50'}\n")
        outputs, _, _ = data_compiler.compile_data(self.data)
        codes = [row["code"] for row in json.loads(outputs["community.json"])["entries"]]
        self.assertIn("Z-zwetschge", codes)

    def test_an_alias_another_entry_already_spells(self):
        self.edit("ingredients/zwiebel.yaml", "    - Zwiebeln\n",
                  "    - Zwiebeln\n    - Knoblauchzehe\n")
        self.assertFails("'Knoblauchzehe' (Zwiebel) is already spelled 'Knoblauchzehe' by Knoblauch")

    def test_an_alias_that_differs_only_by_normalization(self):
        self.edit("ingredients/zwiebel.yaml", "    - Zwiebeln\n", "    - Rot-Kohl\n")
        self.assertFails("'Rot-Kohl' (Zwiebel) is already spelled 'Rotkohl' by Rotkohl")

    def test_a_spelling_the_entry_already_has(self):
        self.edit("ingredients/weisswein.yaml", "    - trockener Weißwein\n",
                  "    - trockener Weißwein\n    - Weisswein\n")
        self.assertFails("'Weisswein' and 'Weißwein' are the same spelling once normalized ('weisswein'); keep one")

    def test_a_key_written_twice(self):
        self.edit("ingredients/zwiebel.yaml", "  category: vegetables\n",
                  "  category: vegetables\n  category: fruit\n")
        self.assertFails("zwiebel.yaml:7: the key 'category' is written twice (first at line 6)")

    def test_an_anchor(self):
        self.write("ingredients/test.yaml", "- &a\n  id: test\n  name: Test\n")
        self.assertFails("test.yaml:1: anchors and aliases are not allowed")

    def test_a_yaml_boolean_where_a_number_belongs(self):
        self.edit("ingredients/zwiebel.yaml", "{Stk.: 110}", "{Stk.: no}")
        self.assertFails("zwiebel.yaml: 0/measures/Stk.: 'no' is not valid")

    def test_a_code_nobody_has(self):
        self.edit("ingredients/zwiebel.yaml", "raw: [G480100]", "raw: [G999999]")
        self.assertFails("Zwiebel [raw] names G999999, which is neither in bls.json nor written inline")

    def test_a_root_without_an_answer(self):
        self.write("ingredients/test.yaml",
                   "- id: test\n  name: Testwort\n  category: vegetables\n")
        self.assertFails("Testwort maps to no code and does not say `nutrition: without`")

    def test_a_file_named_after_something_else(self):
        self.write("ingredients/test.yaml",
                   "- id: testwort\n  name: Testwort\n  category: vegetables\n"
                   "  nutrition: without\n")
        self.assertFails("the file is named 'test', its root has the id 'testwort'")

    def test_a_product_behind_a_generic_word(self):
        self.write("products/acme.yaml", "\n".join([
            "- id: acme-muesli",
            "  kind: product",
            "  name: Acme Müsli",
            "  brand: Acme",
            "  aliases: [Proteinmüsli]",
            "  category: grains",
            "  nutrition:",
            "    unspecified:",
            "      - code: Z-acme-muesli",
            "        name: Acme Müsli",
            "        source: Etikett",
            "        per100g: {kcal: '400'}",
            "",
        ]))
        self.assertFails(
            "the product spelling 'Proteinmüsli' does not name the brand 'Acme'",
            "the product row Z-acme-muesli has no 'checked'",
            "the product row Z-acme-muesli has no 'per'",
        )


if __name__ == "__main__":
    unittest.main()
