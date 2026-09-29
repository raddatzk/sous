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

    def test_the_real_data_compiles(self):
        outputs, _ = data_compiler.compile_data(self.data)
        self.assertEqual(set(outputs), {
            "kitchen_words.json", "curation.json", "measures.json",
            "aisles.json", "community.json",
        })

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
            "      - code: Z000009",
            "        name: Acme Müsli",
            "        source: Etikett",
            "        per100g: {kcal: '400'}",
            "",
        ]))
        self.assertFails(
            "the product spelling 'Proteinmüsli' does not name the brand 'Acme'",
            "the product row Z000009 has no 'checked'",
            "the product row Z000009 has no 'per'",
        )


if __name__ == "__main__":
    unittest.main()
