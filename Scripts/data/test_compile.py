"""Tests for compile.py: the real Data/ compiles to the resources, and a
broken copy of it fails with a message that says what is wrong and where.

    python3 -m unittest discover -s Scripts/data -p 'test_*.py'
"""
from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from datetime import date
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
            "aisles.json", "community.json", "sources.json", "ids.json", "manifest.json",
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

    # Two products as a label gives them, as fixtures only: Data/ holds no
    # product until the cook brings the packs.
    BUTTER = [
        "- id: testmarke-vegane-butter",
        "  kind: product",
        "  name: Testmarke Vegane Butter",
        "  brand: Testmarke",
        "  aliases: [Testmarke vegane Butter Block]",
        "  category: dairy",
        "  ean: ['0012345678905', '4006381333931']",
        "  nutrition:",
        "    unspecified:",
        "      - code: Z-testmarke-vegane-butter",
        "        name: Testmarke Vegane Butter",
        "        source: Nährwertdeklaration der Packung",
        "        checked: '2026-10-02'",
        "        per: as-sold",
        "        per100g: {kj: '2988', fatG: '80', saturatedFatG: '37', carbsG: '0.5',",
        "                  sugarG: '0.5', proteinG: '0.2', saltG: '1.2'}",
    ]
    DRINK = [
        "- id: testmarke-haferdrink",
        "  kind: product",
        "  name: Testmarke Haferdrink",
        "  brand: Testmarke",
        "  category: drinks",
        "  ean: ['96385074']",
        "  discontinued: 'true'",
        "  density: '1.03'",
        "  nutrition:",
        "    unspecified:",
        "      - code: Z-testmarke-haferdrink",
        "        name: Testmarke Haferdrink",
        "        source: Nährwertdeklaration der Packung",
        "        checked: '2026-10-02'",
        "        per: as-sold",
        "        per100ml: {kcal: '46', kj: '193', fatG: '1.5', carbsG: '7.0', fiberG: '0.8',",
        "                   proteinG: '1.0', saltG: '0.1'}",
    ]

    def write_products(self, *lines: str) -> None:
        self.write("products/testmarke.yaml", "\n".join(self.BUTTER + self.DRINK + list(lines)) + "\n")

    def test_products_compile_with_their_label(self):
        self.write_products()
        outputs, warnings, _ = data_compiler.compile_data(self.data)
        words = {w["name"]: w for w in json.loads(outputs["kitchen_words.json"])}
        butter = words["Testmarke Vegane Butter"]
        self.assertEqual(butter["kind"], "product")
        self.assertEqual(butter["brand"], "Testmarke")
        # An EAN is a string: its leading zeros are part of it.
        self.assertEqual(butter["ean"], ["0012345678905", "4006381333931"])
        self.assertNotIn("discontinued", butter)
        self.assertIs(words["Testmarke Haferdrink"]["discontinued"], True)
        # A plain ingredient's row is unchanged.
        self.assertNotIn("kind", words["Zwiebel"])

        rows = {r["code"]: r for r in json.loads(outputs["community.json"])["entries"]}
        values = rows["Z-testmarke-vegane-butter"]["perHundredGrams"]
        self.assertAlmostEqual(values["kcal"], 2988 / 4.184, places=2)
        self.assertNotIn("kj", values)
        self.assertEqual(values["sodiumMg"], 480)
        # Absent stays absent: the label declares no fibre and no vitamins.
        self.assertNotIn("fiberG", values)
        self.assertNotIn("vitaminCMg", values)
        self.assertEqual(rows["Z-testmarke-vegane-butter"]["checked"], "2026-10-02")
        self.assertEqual(rows["Z-testmarke-vegane-butter"]["per"], "as-sold")

        # Per 100 ml through the density; the label's kcal beats its kJ.
        drink = rows["Z-testmarke-haferdrink"]["perHundredGrams"]
        self.assertAlmostEqual(drink["kcal"], 46 / 1.03, places=2)
        self.assertAlmostEqual(drink["fiberG"], 0.8 / 1.03, places=2)
        self.assertAlmostEqual(drink["sodiumMg"], 40 / 1.03, places=2)
        self.assertTrue(any("Z-testmarke-vegane-butter: kcal from kJ" in w for w in warnings))
        self.assertTrue(any("Z-testmarke-haferdrink: per 100 ml through the density 1.03" in w
                            for w in warnings))

    def test_a_product_spelled_like_an_ingredient(self):
        self.write_products("- id: testmarke-zwiebel", "  kind: product", "  name: Zwiebel",
                            "  brand: Testmarke", "  category: vegetables", "  nutrition:",
                            "    unspecified:", "      - code: Z-testmarke-zwiebel",
                            "        name: Zwiebel", "        source: Etikett",
                            "        checked: '2026-10-02'", "        per: as-sold",
                            "        per100g: {kcal: '40'}")
        self.assertFails("the product spelling 'Zwiebel' does not name the brand 'Testmarke'",
                         "'Zwiebel' (Zwiebel) is already spelled")

    def test_a_product_without_values(self):
        """Name and brand are enough; `like` makes it an estimate, and
        without it the product is simply not computed."""
        self.write_products(
            "- id: testmarke-margarine", "  kind: product", "  name: Testmarke Margarine",
            "  brand: Testmarke", "  category: dairy", "  like: margarine",
            "- id: testmarke-ghee", "  kind: product", "  name: Testmarke Ghee",
            "  brand: Testmarke", "  category: dairy",
        )
        outputs, _, _ = data_compiler.compile_data(self.data)
        words = {w["name"]: w for w in json.loads(outputs["kitchen_words.json"])}
        self.assertEqual(words["Testmarke Margarine"]["like"], "margarine")
        self.assertNotIn("like", words["Testmarke Ghee"])
        curated = json.loads(outputs["curation.json"])["words"]
        self.assertNotIn("Testmarke Margarine", curated)
        self.assertNotIn("Testmarke Ghee", curated)

    def test_like_names_a_generic_word(self):
        self.write_products(
            "- id: testmarke-margarine", "  kind: product", "  name: Testmarke Margarine",
            "  brand: Testmarke", "  category: dairy", "  like: margarin",
            "- id: testmarke-butterersatz", "  kind: product", "  name: Testmarke Butterersatz",
            "  brand: Testmarke", "  category: dairy", "  like: testmarke-vegane-butter",
        )
        self.assertFails("Testmarke Margarine is like 'margarin', which is no id",
                         "Testmarke Butterersatz is like the product Testmarke Vegane Butter")

    def test_label_values_replace_like(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "  category: dairy\n",
                  "  category: dairy\n  like: margarine\n")
        outputs, warnings, _ = data_compiler.compile_data(self.data)
        words = {w["name"]: w for w in json.loads(outputs["kitchen_words.json"])}
        self.assertNotIn("like", words["Testmarke Vegane Butter"])
        self.assertTrue(any("Testmarke Vegane Butter has label values; they replace "
                            "`like: margarine`" in w for w in warnings))

    def test_a_wrong_ean(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "'4006381333931'", "'4006381333932'")
        self.assertFails("Testmarke Vegane Butter's EAN 4006381333932 has a wrong check digit")

    def test_one_ean_on_two_products(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "ean: ['96385074']", "ean: ['4006381333931']")
        self.assertFails("the EAN 4006381333931 of Testmarke Haferdrink is "
                         "Testmarke Vegane Butter's already")

    def test_per_100_ml_without_a_density(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "  density: '1.03'\n", "")
        self.assertFails("the row Z-testmarke-haferdrink is per 100 ml, but Testmarke "
                         "Haferdrink has no density")

    def test_a_label_without_energy(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "per100g: {kj: '2988', ", "per100g: {")
        self.assertFails("the product row Z-testmarke-vegane-butter has no energy")

    def test_salt_and_sodium(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "saltG: '1.2'", "saltG: '1.2', sodiumMg: '480'")
        self.assertFails("the row Z-testmarke-vegane-butter gives salt and sodium")

    def test_a_row_with_both_bases(self):
        self.write_products()
        self.edit("products/testmarke.yaml", "        per100ml: {kcal: '46'",
                  "        per100g: {kcal: '45'}\n        per100ml: {kcal: '46'")
        self.assertFails("Z-testmarke-haferdrink")


class Manifest(unittest.TestCase):
    """manifest.json: the set's hashes, and a dataVersion that moves only
    when the content does, as `YYYYMMDDnn`."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.resources = self.tmp / "Resources"
        shutil.copytree(data_compiler.RESOURCES, self.resources)
        self.data = self.tmp / "Data"
        shutil.copytree(data_compiler.DATA, self.data)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def compile(self, today: date) -> dict:
        outputs, _, _ = data_compiler.compile_data(self.data, self.resources, today=today)
        for name, text in outputs.items():
            (self.resources / name).write_text(text, encoding="utf-8")
        return json.loads(outputs[data_compiler.MANIFEST])

    def change_the_data(self):
        path = self.data / "ingredients/zwiebel.yaml"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "    - Speisezwiebel\n", "    - Speisezwiebel\n    - Testzwiebel\n", 1), encoding="utf-8")

    def test_the_checked_in_manifest_names_the_resources(self):
        manifest = json.loads((data_compiler.RESOURCES / data_compiler.MANIFEST).read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], data_compiler.SCHEMA)
        self.assertEqual(sorted(manifest["files"]), sorted(data_compiler.SET_FILES))
        for name, digest in manifest["files"].items():
            with self.subTest(file=name):
                self.assertEqual(
                    data_compiler.sha256_hex((data_compiler.RESOURCES / name).read_bytes()), digest)
        self.assertEqual(data_compiler.set_digest(manifest["files"]), manifest["sha256"])

    def test_unchanged_data_keeps_its_version(self):
        before = self.compile(date(2026, 9, 30))
        after = self.compile(date(2027, 1, 1))
        self.assertEqual(after, before)

    def test_changed_data_takes_the_day(self):
        before = self.compile(date(2026, 9, 30))
        self.change_the_data()
        after = self.compile(date(2026, 12, 24))
        self.assertEqual(after["dataVersion"], 2026122400)
        self.assertNotEqual(after["sha256"], before["sha256"])
        self.assertNotEqual(after["files"]["kitchen_words.json"], before["files"]["kitchen_words.json"])
        self.assertEqual(after["files"]["bls.json"], before["files"]["bls.json"])

    def test_a_second_release_the_same_day_counts_up(self):
        self.assertEqual(data_compiler.next_version(2026122400, date(2026, 12, 24)), 2026122401)
        self.assertEqual(data_compiler.next_version(None, date(2026, 12, 24)), 2026122400)

    def test_the_series_never_goes_back(self):
        # A hundredth release in a day spills into the next number, and a
        # clock set back cannot lower it.
        self.assertEqual(data_compiler.next_version(2026122499, date(2026, 12, 24)), 2026122500)
        self.assertEqual(data_compiler.next_version(2026122405, date(2026, 1, 1)), 2026122406)

    def test_bls_json_is_part_of_the_set(self):
        before = self.compile(date(2026, 9, 30))
        bls = self.resources / "bls.json"
        bls.write_bytes(bls.read_bytes() + b" ")
        after = self.compile(date(2026, 10, 1))
        self.assertEqual(after["dataVersion"], 2026100100)
        self.assertNotEqual(after["files"]["bls.json"], before["files"]["bls.json"])

    def test_a_stale_manifest_is_caught(self):
        self.compile(date(2026, 9, 30))
        self.change_the_data()
        outputs, _, _ = data_compiler.compile_data(self.data, self.resources, today=date(2026, 10, 1))
        on_disk = (self.resources / data_compiler.MANIFEST).read_text(encoding="utf-8")
        self.assertNotEqual(outputs[data_compiler.MANIFEST], on_disk)

    def test_since_wants_a_higher_version_for_new_data(self):
        before = {"schema": 1, "dataVersion": 2026093000, "sha256": "a"}
        self.assertEqual(data_compiler.version_errors(before, {**before}), [])
        self.assertEqual(data_compiler.version_errors(before, {**before, "sha256": "b"}),
                         ["the data changed, but dataVersion stayed 2026093000"])
        self.assertEqual(
            data_compiler.version_errors(before, {**before, "sha256": "b", "dataVersion": 2026093001}), [])
        self.assertEqual(data_compiler.version_errors(before, {**before, "dataVersion": 2026092900}),
                         ["dataVersion went back from 2026093000 to 2026092900"])
        self.assertEqual(data_compiler.version_errors(None, before), [])


if __name__ == "__main__":
    unittest.main()
