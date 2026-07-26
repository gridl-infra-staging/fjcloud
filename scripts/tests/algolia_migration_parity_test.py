#!/usr/bin/env python3
"""Known-answer tests for Algolia migration hit parity."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))

from algolia_migration_parity import compare_hit_sets  # noqa: E402

FIXTURE = (
    REPO_ROOT
    / "scripts"
    / "tests"
    / "fixtures"
    / "algolia_migration_parity_source.json"
)


def fixture_hits() -> list[dict[str, object]]:
    with FIXTURE.open(encoding="utf-8") as handle:
        return json.load(handle)


class AlgoliaMigrationParityTest(unittest.TestCase):
    def test_identical_sets_report_empty_diff_and_matching_count(self) -> None:
        source = fixture_hits()
        report = compare_hit_sets(source, list(reversed(source)))

        self.assertEqual(report["count_source"], 3)
        self.assertEqual(report["count_migrated"], 3)
        self.assertEqual(report["only_in_source"], [])
        self.assertEqual(report["only_in_migrated"], [])
        self.assertEqual(report["field_mismatches"], [])

    def test_missing_document_is_flagged(self) -> None:
        source = fixture_hits()
        report = compare_hit_sets(source, source[:2])

        self.assertEqual(report["count_source"], 3)
        self.assertEqual(report["count_migrated"], 2)
        self.assertEqual(report["only_in_source"], ["doc-3"])
        self.assertEqual(report["only_in_migrated"], [])
        self.assertEqual(report["field_mismatches"], [])

    def test_extra_document_is_flagged(self) -> None:
        source = fixture_hits()
        migrated = source + [{"objectID": "doc-4", "title": "Delta"}]
        report = compare_hit_sets(source, migrated)

        self.assertEqual(report["count_source"], 3)
        self.assertEqual(report["count_migrated"], 4)
        self.assertEqual(report["only_in_source"], [])
        self.assertEqual(report["only_in_migrated"], ["doc-4"])
        self.assertEqual(report["field_mismatches"], [])

    def test_rerun_into_populated_target_stays_at_known_count(self) -> None:
        source = fixture_hits()

        with self.assertRaisesRegex(ValueError, "migrated_object_id_duplicate"):
            compare_hit_sets(source, source + source)

    def test_mutated_field_is_flagged(self) -> None:
        source = fixture_hits()
        migrated = fixture_hits()
        migrated[1]["price"] = 251
        report = compare_hit_sets(source, migrated)

        self.assertEqual(report["only_in_source"], [])
        self.assertEqual(report["only_in_migrated"], [])
        self.assertEqual(
            report["field_mismatches"],
            [
                {
                    "objectID": "doc-2",
                    "source": {"objectID": "doc-2", "price": 250, "tags": ["y"], "title": "Beta"},
                    "migrated": {"objectID": "doc-2", "price": 251, "tags": ["y"], "title": "Beta"},
                }
            ],
        )

    def test_response_metadata_is_ignored_but_customer_underscore_fields_are_compared(
        self,
    ) -> None:
        source = fixture_hits()
        migrated = fixture_hits()
        migrated[0]["_highlightResult"] = {
            "title": {"value": "<em>Alpha</em>", "matchLevel": "full"}
        }
        migrated[0]["_rankingInfo"] = {"geoDistance": 42}
        migrated[0]["_geoloc"] = {"lat": 41.0, "lng": -73.0}
        report = compare_hit_sets(source, migrated)

        self.assertEqual(report["only_in_source"], [])
        self.assertEqual(report["only_in_migrated"], [])
        self.assertEqual(
            report["field_mismatches"],
            [
                {
                    "objectID": "doc-1",
                    "source": {
                        "_geoloc": {"lat": 40.0, "lng": -73.0},
                        "objectID": "doc-1",
                        "price": 100,
                        "tags": ["x", "y"],
                        "title": "Alpha",
                    },
                    "migrated": {
                        "_geoloc": {"lat": 41.0, "lng": -73.0},
                        "objectID": "doc-1",
                        "price": 100,
                        "tags": ["x", "y"],
                        "title": "Alpha",
                    },
                }
            ],
        )

    def test_missing_non_string_and_duplicate_object_ids_are_rejected(self) -> None:
        for hits in ([{"title": "No ID"}], [{"objectID": 1}], [{"objectID": "x"}, {"objectID": "x"}]):
            with self.subTest(hits=hits):
                with self.assertRaises(ValueError):
                    compare_hit_sets(hits, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
