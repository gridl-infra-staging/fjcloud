#!/usr/bin/env python3
"""TDD coverage for Stage 3 deterministic rule application."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from apply_rule import apply_rules, main


def _row(
    *,
    source_path: str,
    source_type: str,
    source_row_number: int,
    row_order: int,
    title: str,
    body: str,
    priority: str | None,
    gate: str | None,
    owner_files: list[str],
    effort_band: str = "M",
) -> dict[str, object]:
    return {
        "source_path": source_path,
        "source_type": source_type,
        "source_row_number": source_row_number,
        "row_order": row_order,
        "title": title,
        "body": body,
        "priority": priority,
        "gate": gate,
        "effort_band": effort_band,
        "owner_files": owner_files,
    }


def _recommendations(rows: list[dict[str, object]], coverage_status: str = "ok") -> dict[str, object]:
    return {
        "sources": [
            {
                "source_path": "docs/audits/feature-parity/20260524_fjcloud_vs_engine_dashboard/SUMMARY.md",
                "source_type": "parity",
                "section_found": True,
                "parse_status": "ok",
                "row_count": len([r for r in rows if r["source_type"] == "parity"]),
            },
            {
                "source_path": "docs/audits/test-coverage/20260524_console_index_tabs/SUMMARY.md",
                "source_type": "coverage",
                "section_found": coverage_status == "ok",
                "parse_status": coverage_status,
                "row_count": len([r for r in rows if r["source_type"] == "coverage"]),
            },
        ],
        "rows": rows,
    }


class ApplyRuleTests(unittest.TestCase):
    def test_three_clause_partition_and_exactly_once_for_non_overrides(self) -> None:
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=1,
                row_order=1,
                title="Protect console index setup flow",
                body="Customer path in setup",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=2,
                row_order=2,
                title="Fix signup token visibility",
                body="Touches onboarding credentials",
                priority="P0",
                gate="pre-W4-cutover",
                owner_files=["infra/aggregation-job/src/main.rs"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=1,
                row_order=1,
                title="Lower-risk cleanup in metrics docs",
                body="No customer path",
                priority="P1",
                gate="pre-L6",
                owner_files=["infra/aggregation-job/src/rollup.rs"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=2,
                row_order=2,
                title="Post-launch cache cleanup",
                body="Only after launch",
                priority="P0",
                gate="post-L7",
                owner_files=["web/src/routes/console/indexes/+page.server.ts"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=3,
                row_order=3,
                title="Tune aggregation step size",
                body="No customer-visible tokens",
                priority="P0",
                gate="pre-L6",
                owner_files=["infra/aggregation-job/src/rollup.rs"],
            ),
        ]

        to_author, to_defer = apply_rules(
            _recommendations(rows),
            demo_owner_files_seed=["web/src/lib/demo-indexes/catalog.ts"],
        )

        authored_keys = {
            (r.get("source_path"), r.get("source_row_number"), r.get("title"))
            for r in to_author["rows"]
            if not r.get("standing_inclusion")
        }
        deferred_keys = {
            (r.get("source_path"), r.get("source_row_number"), r.get("title"))
            for r in to_defer["rows"]
            if not r.get("forced_defer")
        }
        input_keys = {
            (r.get("source_path"), r.get("source_row_number"), r.get("title"))
            for r in rows
        }

        self.assertEqual(authored_keys | deferred_keys, input_keys)
        self.assertTrue(authored_keys.isdisjoint(deferred_keys))

        authored_titles = [r["title"] for r in to_author["rows"]]
        self.assertIn("Protect console index setup flow", authored_titles)
        self.assertIn("Fix signup token visibility", authored_titles)

    def test_demo_override_adopts_existing_row_exactly_once(self) -> None:
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=7,
                row_order=1,
                title="Implement demo index loader in console flow",
                body="Requested standing inclusion",
                priority="P1",
                gate="post-L7",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=3,
                row_order=1,
                title="Protect checkout billing banner",
                body="Customer-facing",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/lib/billing/client.ts"],
            ),
        ]

        to_author, to_defer = apply_rules(_recommendations(rows))

        demo_rows = [
            r
            for r in to_author["rows"]
            if "demo" in r["title"].lower()
            and ("loader" in r["title"].lower() or "index" in r["title"].lower())
        ]
        self.assertEqual(len(demo_rows), 1)
        self.assertTrue(demo_rows[0].get("standing_override_applied"))
        self.assertFalse(demo_rows[0].get("standing_inclusion"))
        self.assertTrue(demo_rows[0].get("launch_blocking"))

        defer_demo = [
            r
            for r in to_defer["rows"]
            if "demo" in r["title"].lower()
            and ("loader" in r["title"].lower() or "index" in r["title"].lower())
        ]
        self.assertEqual(defer_demo, [])

    def test_demo_override_synthesizes_when_missing(self) -> None:
        rows = [
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=1,
                row_order=1,
                title="Protect portal login handoff",
                body="customer auth",
                priority="P0",
                gate="pre-L6",
                owner_files=["infra/api/src/routes/public/signup.rs"],
            )
        ]

        to_author, _ = apply_rules(
            _recommendations(rows),
            demo_owner_files_seed=["web/src/lib/demo-indexes/catalog.ts"],
        )
        demo_rows = [r for r in to_author["rows"] if r.get("standing_inclusion")]
        self.assertEqual(len(demo_rows), 1)
        self.assertIn("demo", demo_rows[0]["title"].lower())
        self.assertEqual(demo_rows[0]["owner_files"], ["web/src/lib/demo-indexes/catalog.ts"])

    def test_duplicate_demo_rows_keep_non_adopted_row_in_partition(self) -> None:
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=5,
                row_order=1,
                title="Implement demo index loader in console flow",
                body="Requested standing inclusion",
                priority="P1",
                gate="post-L7",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=2,
                row_order=2,
                title="Follow-up demo index loader cleanup",
                body="also demo loader path",
                priority="P1",
                gate="post-L7",
                owner_files=["web/src/lib/demo-indexes/catalog.ts"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=3,
                row_order=3,
                title="Protect checkout billing banner",
                body="Customer-facing",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/lib/billing/client.ts"],
            ),
        ]

        to_author, to_defer = apply_rules(_recommendations(rows))

        authored_demo_rows = [
            row
            for row in to_author["rows"]
            if "demo" in row.get("title", "").lower()
            and ("loader" in row.get("title", "").lower() or "index" in row.get("title", "").lower())
        ]
        deferred_demo_rows = [
            row
            for row in to_defer["rows"]
            if "demo" in row.get("title", "").lower()
            and ("loader" in row.get("title", "").lower() or "index" in row.get("title", "").lower())
        ]

        self.assertEqual(len(authored_demo_rows), 1)
        self.assertEqual(
            authored_demo_rows[0].get("title"),
            "Implement demo index loader in console flow",
        )
        self.assertEqual(len(deferred_demo_rows), 1)
        self.assertEqual(
            deferred_demo_rows[0].get("title"),
            "Follow-up demo index loader cleanup",
        )


    def test_demo_named_ask_adopted_while_other_demo_rows_still_partition(self) -> None:
        rows = [
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=1,
                row_order=1,
                title="AAA demo index prep follow-up",
                body="demo index prep",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/lib/demo-indexes/catalog.ts"],
            ),
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=2,
                row_order=2,
                title="Implement demo index loader in console flow",
                body="Requested standing inclusion",
                priority="P1",
                gate="post-L7",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
        ]

        to_author, to_defer = apply_rules(_recommendations(rows))

        override_rows = [r for r in to_author["rows"] if r.get("standing_override_applied")]
        self.assertEqual(len(override_rows), 1)
        self.assertEqual(override_rows[0]["title"], "Implement demo index loader in console flow")

        non_override_authored_titles = {
            r.get("title") for r in to_author["rows"] if not r.get("standing_override_applied")
        }
        self.assertIn("AAA demo index prep follow-up", non_override_authored_titles)

    def test_duplicate_exact_named_demo_rows_collapse_to_single_override(self) -> None:
        # Two copies of the EXACT standing ask title arrive from different sources.
        # The second copy is independently customer-visible/launch-blocking, so under
        # naive per-row evaluation it would leak back into to_author. The standing
        # override must collapse all exact-title copies into one adopted row.
        exact_title = "Implement demo index loader in console flow"
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=5,
                row_order=1,
                title=exact_title,
                body="Requested standing inclusion",
                priority="P1",
                gate="post-L7",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=2,
                row_order=2,
                title=exact_title,
                body="Duplicate copy of the same standing ask",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/lib/demo-indexes/catalog.ts"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=3,
                row_order=3,
                title="Protect checkout billing banner",
                body="Customer-facing",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/lib/billing/client.ts"],
            ),
        ]

        to_author, to_defer = apply_rules(_recommendations(rows))

        authored_exact = [r for r in to_author["rows"] if r.get("title") == exact_title]
        deferred_exact = [r for r in to_defer["rows"] if r.get("title") == exact_title]

        self.assertEqual(len(authored_exact), 1)
        self.assertTrue(authored_exact[0].get("standing_override_applied"))
        self.assertEqual(deferred_exact, [])

    def test_billing_plan_is_forced_to_defer_with_reason_code(self) -> None:
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=4,
                row_order=1,
                title="BillingPlan Shared to Paid rename in rust",
                body="internal storage seam",
                priority="P0",
                gate="pre-L6",
                owner_files=["infra/billing/src/lib.rs"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=8,
                row_order=1,
                title="Guard customer trial cancel flow",
                body="customer visible",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
        ]

        to_author, to_defer = apply_rules(
            _recommendations(rows),
            demo_owner_files_seed=["web/src/lib/demo-indexes/catalog.ts"],
        )

        authored_titles = [r["title"].lower() for r in to_author["rows"]]
        self.assertFalse(any("billingplan" in title or "shared" in title for title in authored_titles))

        forced = [r for r in to_defer["rows"] if r.get("forced_defer")]
        self.assertEqual(len(forced), 1)
        self.assertEqual(forced[0]["defer_reason_code"], "billingplan_rename_internal_storage")

    def test_non_billingplan_shared_row_stays_in_normal_partition(self) -> None:
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=4,
                row_order=1,
                title="BillingPlan Shared to Paid rename in rust",
                body="internal storage seam",
                priority="P0",
                gate="pre-L6",
                owner_files=["infra/billing/src/lib.rs"],
            ),
            _row(
                source_path="coverage.md",
                source_type="coverage",
                source_row_number=9,
                row_order=2,
                title="Refactor shared helper for auth flow",
                body="Protect customer login boundary",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/routes/console/indexes/+page.svelte"],
            ),
        ]

        to_author, to_defer = apply_rules(
            _recommendations(rows),
            demo_owner_files_seed=["web/src/lib/demo-indexes/catalog.ts"],
        )

        authored_keys = {
            (r.get("source_path"), r.get("source_row_number"), r.get("title"))
            for r in to_author["rows"]
            if not r.get("standing_inclusion")
        }
        deferred_keys = {
            (r.get("source_path"), r.get("source_row_number"), r.get("title"))
            for r in to_defer["rows"]
            if not r.get("forced_defer")
        }

        self.assertIn(
            ("coverage.md", 9, "Refactor shared helper for auth flow"),
            authored_keys | deferred_keys,
        )
        self.assertIn(
            ("coverage.md", 9, "Refactor shared helper for auth flow"),
            authored_keys,
        )

    def test_output_order_is_deterministic(self) -> None:
        rows = [
            _row(
                source_path="b.md",
                source_type="coverage",
                source_row_number=3,
                row_order=2,
                title="Fix signup flow",
                body="signup token",
                priority="P0",
                gate="pre-W4-cutover",
                owner_files=["infra/aggregation-job/src/main.rs"],
            ),
            _row(
                source_path="a.md",
                source_type="parity",
                source_row_number=1,
                row_order=1,
                title="Improve console billing panel",
                body="billing",
                priority="P0",
                gate="pre-L6",
                owner_files=["web/src/lib/billing/client.ts"],
            ),
        ]

        rec = _recommendations(rows)
        first_author, first_defer = apply_rules(rec, demo_owner_files_seed=["web/src/lib/demo-indexes/catalog.ts"])
        second_author, second_defer = apply_rules(rec, demo_owner_files_seed=["web/src/lib/demo-indexes/catalog.ts"])

        self.assertEqual(
            json.dumps(first_author, sort_keys=True),
            json.dumps(second_author, sort_keys=True),
        )
        self.assertEqual(
            json.dumps(first_defer, sort_keys=True),
            json.dumps(second_defer, sort_keys=True),
        )

    def test_partial_parse_still_writes_both_outputs_and_warnings(self) -> None:
        rows = [
            _row(
                source_path="parity.md",
                source_type="parity",
                source_row_number=1,
                row_order=1,
                title="Protect signup form",
                body="signup",
                priority="P0",
                gate="pre-L6",
                owner_files=["infra/api/src/routes/public/signup.rs"],
            )
        ]
        recommendations = _recommendations(rows, coverage_status="missing_prioritized_recommendations")

        with tempfile.TemporaryDirectory() as tmpdir:
            input_path = Path(tmpdir) / "recommendations.json"
            output_dir = Path(tmpdir) / "triage"
            output_dir.mkdir(parents=True, exist_ok=True)
            input_path.write_text(json.dumps(recommendations), encoding="utf-8")

            exit_code = main(["apply_rule.py", str(input_path), str(output_dir)])
            self.assertEqual(exit_code, 0)

            to_author_path = output_dir / "to_author.json"
            to_defer_path = output_dir / "to_defer.json"
            self.assertTrue(to_author_path.exists())
            self.assertTrue(to_defer_path.exists())

            to_author = json.loads(to_author_path.read_text(encoding="utf-8"))
            to_defer = json.loads(to_defer_path.read_text(encoding="utf-8"))

            self.assertIn("metadata", to_author)
            self.assertIn("metadata", to_defer)
            self.assertEqual(len(to_author["metadata"]["source_warnings"]), 1)
            self.assertEqual(
                to_author["metadata"]["source_warnings"][0]["parse_status"],
                "missing_prioritized_recommendations",
            )

            authored_keys = {
                (r.get("source_path"), r.get("source_row_number"), r.get("title"))
                for r in to_author["rows"]
                if not r.get("standing_inclusion")
            }
            deferred_keys = {
                (r.get("source_path"), r.get("source_row_number"), r.get("title"))
                for r in to_defer["rows"]
                if not r.get("forced_defer")
            }
            self.assertEqual(authored_keys | deferred_keys, {("parity.md", 1, "Protect signup form")})


if __name__ == "__main__":
    unittest.main()
