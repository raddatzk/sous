"""Tests for inbox.py: reading submissions, the cap, the block, a night's run.

    python3 -m unittest discover -s Scripts/data -p 'test_*.py'
"""

from __future__ import annotations

import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inbox  # noqa: E402


def record(name, creator, items, created=1, schema=1):
    return {
        "recordName": name,
        "recordType": "CatalogSubmission",
        "created": {"timestamp": created, "userRecordName": creator},
        "fields": {
            "schema": {"value": schema},
            "items": {"value": json.dumps(items, ensure_ascii=False)},
            "app": {"value": "1.0 (7)"},
            "dataVersion": {"value": 2026100200},
        },
    }


COUNTS_AS = {"kind": "countsAs", "name": "dünne Kokosmilch", "target": {"id": "kokosmilch", "name": "Kokosmilch"},
             "recipes": 2, "line": "200 ml dünne Kokosmilch"}


class FakeCloudKit:
    def __init__(self, records):
        self.records = list(records)
        self.deleted = []

    def query_page(self, record_type, sort_by=None, continuation=None, **_):
        assert record_type == "CatalogSubmission"
        start = int(continuation or 0)
        page = self.records[start:start + 2]
        more = start + 2 < len(self.records)
        return page, (str(start + 2) if more else None)

    def delete(self, names):
        self.deleted += names
        self.records = [r for r in self.records if r["recordName"] not in names]


class FakeGitHub:
    def __init__(self, issues=None, fail_on=None):
        self.issues = list(issues or [])
        self.comments = []
        self.fail_on = fail_on

    def ensure_labels(self):
        pass

    def open_issues(self):
        return [i for i in self.issues if i["state"] == "open"]

    def create(self, title, body, labels):
        if self.fail_on and self.fail_on in title:
            raise RuntimeError("GitHub down")
        issue = {"number": len(self.issues) + 1, "title": title, "body": body, "labels": labels, "state": "open"}
        self.issues.append(issue)
        return issue

    def update(self, number, body, labels):
        issue = self.issues[number - 1]
        issue["body"] = body
        issue["labels"] = sorted(set(issue["labels"]) | set(labels))

    def comment(self, number, text):
        self.comments.append((number, text))

    def issue(self, number):
        return self.issues[number - 1]

    def close(self, number):
        self.issues[number - 1]["state"] = "closed"

    def add_labels(self, number, names):
        self.issues[number - 1]["labels"] = sorted(set(self.issues[number - 1]["labels"]) | set(names))

    def pulls(self, repository):
        return getattr(self, "sous_pulls", [])


def night(cloudkit, github):
    return inbox.run(cloudkit, github, out=io.StringIO())


class CleanItemTests(unittest.TestCase):
    def test_keeps_the_wire_fields(self):
        item = inbox.clean_item({
            "kind": "values", "name": " Kichererbsen ", "catalogID": "kichererbsen",
            "values": {"kcal": 120, "proteinG": 7.5, "absent": ["vitaminCMg"]}, "source": "Dose, Marke X",
            "weights": {"Dose": {"grams": 240, "state": "cooked"}, "EL": {"grams": 15, "state": "unspecified"}},
            "recipes": 3, "line": "1 Dose Kichererbsen",
        })
        self.assertEqual(item["name"], "Kichererbsen")
        self.assertEqual(item["values"], {"kcal": 120, "proteinG": 7.5, "absent": ["vitaminCMg"]})
        self.assertEqual(item["weights"], {"Dose": {"grams": 240, "state": "cooked"}, "EL": {"grams": 15}})
        self.assertEqual(item["source"], "Dose, Marke X")

    def test_drops_what_is_malformed(self):
        self.assertIsNone(inbox.clean_item({"kind": "evil", "name": "x"}))
        self.assertIsNone(inbox.clean_item({"kind": "word", "name": "   "}))
        item = inbox.clean_item({
            "kind": "product", "name": "x" * 300, "ean": "12ab", "brand": "B",
            "values": {"kcal": "viel"}, "source": "ignored without values",
            "weights": {"Stk.": {"grams": -3}}, "recipes": True, "target": {"id": 3},
        })
        self.assertEqual(len(item["name"]), 80)
        for key in ("ean", "values", "source", "weights", "target"):
            self.assertNotIn(key, item)
        self.assertEqual(item["recipes"], 0)


class CapTests(unittest.TestCase):
    def test_per_creator_oldest_first(self):
        items = [{"kind": "unknown", "name": f"n{i}", "recipes": 0} for i in range(150)]
        subs = [inbox.read_submission(record("b", "_u1", items, created=2)),
                inbox.read_submission(record("a", "_u1", items, created=1)),
                inbox.read_submission(record("c", "_u2", items[:10], created=3))]
        kept, dropped = inbox.capped(subs)
        self.assertEqual([s.record_name for s in kept], ["a", "b", "c"])
        self.assertEqual([len(s.items) for s in kept], [50, 50, 10])  # a submission holds at most 50
        self.assertEqual(dropped, 0)

        many = [inbox.read_submission(record(f"r{i}", "_u1", items, created=i)) for i in range(5)]
        kept, dropped = inbox.capped(many)
        self.assertEqual(sum(len(s.items) for s in kept), inbox.PER_CREATOR)
        self.assertEqual(dropped, 50)


class NightTests(unittest.TestCase):
    def test_files_one_issue_per_name_without_the_creator_and_deletes(self):
        cloudkit = FakeCloudKit([
            record("r1", "_alice", [COUNTS_AS, {"kind": "word", "name": "Pandanblatt", "recipes": 1}], created=1),
            record("r2", "_bob", [dict(COUNTS_AS, line="100 ml Dünne Kokosmilch", recipes=1)], created=2),
            record("r3", "_carol", [{"kind": "word", "name": "pandanblatt", "recipes": 4}], created=3),
        ])
        github = FakeGitHub()
        result = night(cloudkit, github)

        self.assertEqual(sorted(i["title"] for i in github.issues),
                         ["„Pandanblatt“: neues Wort", "„dünne Kokosmilch“ zählt wie Kokosmilch"])
        coconut = next(i for i in github.issues if "Kokosmilch" in i["title"])
        block = inbox.read_block(coconut["body"])
        self.assertEqual(block["reports"], 2)
        self.assertEqual(block["recipes"], 3)
        self.assertEqual(block["answers"], [{"kind": "countsAs", "target": {"id": "kokosmilch", "name": "Kokosmilch"},
                                             "reports": 2}])
        self.assertEqual(block["lines"], ["200 ml dünne Kokosmilch", "100 ml Dünne Kokosmilch"])
        self.assertEqual(coconut["labels"], ["katalog", "zählt-wie"])
        for issue in github.issues:
            for creator in ("_alice", "_bob", "_carol"):
                self.assertNotIn(creator, issue["body"])
                self.assertNotIn(creator, issue["title"])
        self.assertEqual(sorted(cloudkit.deleted), ["r1", "r2", "r3"])
        self.assertEqual(cloudkit.records, [])
        self.assertEqual(result.failures, [])

    def test_an_open_issue_gets_the_new_count_and_a_comment(self):
        github = FakeGitHub()
        night(FakeCloudKit([record("r1", "_alice", [COUNTS_AS])]), github)
        other = dict(COUNTS_AS, target={"id": "kokosmilch-fettarm", "name": "Kokosmilch, fettarm"})
        night(FakeCloudKit([record("r2", "_bob", [other])]), github)

        self.assertEqual(len(github.issues), 1)
        block = inbox.read_block(github.issues[0]["body"])
        self.assertEqual(block["reports"], 2)
        self.assertEqual([a["target"]["id"] for a in block["answers"]], ["kokosmilch", "kokosmilch-fettarm"])
        self.assertEqual(len(github.comments), 1)
        self.assertIn("Kokosmilch, fettarm", github.comments[0][1])

    def test_a_closed_issue_is_not_reopened(self):
        github = FakeGitHub()
        night(FakeCloudKit([record("r1", "_alice", [COUNTS_AS])]), github)
        github.issues[0]["state"] = "closed"
        night(FakeCloudKit([record("r2", "_bob", [COUNTS_AS])]), github)
        self.assertEqual(len(github.issues), 2)

    def test_a_record_counted_before_is_not_counted_again(self):
        github = FakeGitHub()
        rec = record("r1", "_alice", [COUNTS_AS])
        night(FakeCloudKit([rec]), github)
        # Filed, but the delete never happened: the next night sees it again.
        night(FakeCloudKit([rec]), github)
        self.assertEqual(inbox.read_block(github.issues[0]["body"])["reports"], 1)
        self.assertEqual(github.comments, [])

    def test_a_failing_name_keeps_its_records(self):
        cloudkit = FakeCloudKit([
            record("r1", "_alice", [COUNTS_AS], created=1),
            record("r2", "_bob", [{"kind": "word", "name": "Pandanblatt", "recipes": 1}], created=2),
        ])
        result = night(cloudkit, FakeGitHub(fail_on="Pandanblatt"))
        self.assertEqual(cloudkit.deleted, ["r1"])
        self.assertEqual([r["recordName"] for r in cloudkit.records], ["r2"])
        self.assertEqual(len(result.failures), 1)

    def test_an_unknown_schema_is_left_for_a_newer_script(self):
        cloudkit = FakeCloudKit([record("r1", "_alice", [COUNTS_AS], schema=2)])
        github = FakeGitHub()
        night(cloudkit, github)
        self.assertEqual(github.issues, [])
        self.assertEqual(cloudkit.deleted, [])

    def test_the_block_round_trips_through_the_body(self):
        block, _ = inbox.merge(None, "Greenforce Sojahack", [(
            inbox.read_submission(record("r1", "_a", [])),
            {"kind": "product", "name": "Greenforce Sojahack", "brand": "Greenforce", "ean": "4260000000000",
             "values": {"kcal": 351, "proteinG": 48}, "source": "Etikett", "target": {"id": "sojahack", "name": "Sojahack"},
             "recipes": 1},
        )])
        body = inbox.body(block)
        self.assertEqual(inbox.read_block(body), block)
        self.assertIn("Produkt, Marke Greenforce, EAN 4260000000000", body)
        self.assertIn("351 kcal, 48 g Eiweiß pro 100 g (Quelle: Etikett)", body)
        self.assertEqual(inbox.title(block), "„Greenforce Sojahack“: Produkt (Greenforce)")


def pull(number, branch, state="closed", merged=True, repo="raddatzk/sous"):
    return {"number": number, "state": state, "merged_at": "2026-10-04T10:00:00Z" if merged else None,
            "html_url": f"https://github.com/{repo}/pull/{number}",
            "head": {"ref": branch, "repo": {"full_name": repo}}}


class SweepTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        night(FakeCloudKit([record("r1", "_a", [COUNTS_AS]),
                            record("r2", "_b", [{"kind": "word", "name": "Pandanblatt", "recipes": 1}])]), self.github)
        self.github.issues = [dict(i, labels=list(i["labels"])) for i in self.github.issues]

    def test_a_merged_pull_request_closes_its_issue_with_the_link(self):
        self.github.sous_pulls = [pull(42, "inbox/1-pandanblatt"), pull(43, "inbox/2-x", state="open", merged=False),
                                  pull(44, "feature/inbox", merged=True)]
        done = inbox.sweep(self.github, "raddatzk/sous", out=io.StringIO())
        self.assertEqual(done, ["#1 closed (https://github.com/raddatzk/sous/pull/42)"])
        self.assertEqual(self.github.issues[0]["state"], "closed")
        self.assertEqual(self.github.issues[1]["state"], "open")
        self.assertIn("https://github.com/raddatzk/sous/pull/42", self.github.comments[-1][1])
        # A second night finds the issue closed and says nothing more.
        self.assertEqual(inbox.sweep(self.github, "raddatzk/sous", out=io.StringIO()), [])

    def test_an_unmerged_pull_request_is_said_once(self):
        self.github.sous_pulls = [pull(45, "inbox/2-pandanblatt", merged=False)]
        inbox.sweep(self.github, "raddatzk/sous", out=io.StringIO())
        inbox.sweep(self.github, "raddatzk/sous", out=io.StringIO())
        self.assertEqual(len([c for c in self.github.comments if "ohne Merge" in c[1]]), 1)
        self.assertEqual(self.github.issues[1]["state"], "open")

    def test_a_branch_from_a_fork_is_ignored(self):
        self.github.sous_pulls = [pull(46, "inbox/1-x", repo="someone/sous")]
        self.assertEqual(inbox.sweep(self.github, "raddatzk/sous", out=io.StringIO()), [])


if __name__ == "__main__":
    unittest.main()
