#!/usr/bin/env python3
"""TDD coverage for Stage 2 audit recommendation parsing."""

from __future__ import annotations

import tempfile
import textwrap
import unittest
from pathlib import Path

from parse_audit_recommendations import parse_recommendation_sources


PARITY_FIXTURE = textwrap.dedent(
    """\
    # parity summary

    ## Prioritized recommendations

    1. Implement demo-index-loader in console create-index flow
       Priority: P0
       Effort band: M
       Suggested gate: pre-L6
       Owner-files seed: `web/src/routes/console/indexes/+page.svelte`, `web/src/routes/console/indexes/+page.server.ts`

    2. Add NeuralSearch setup-state gating to Chat tab
       Priority: P1
       Effort band: S
       Suggested gate: post-L7
       Owner-files seed: `web/src/routes/console/indexes/[name]/tabs/ChatTab.svelte`

    ## Out of scope
    """
)

COVERAGE_FIXTURE = textwrap.dedent(
    """\
    # coverage summary

    ## Prioritized Recommendations

    1. Add one unmocked Playwright spec for `AnalyticsTab`. Effort `M`. Suggested gate `post-L7`. Owner files seed: `web/tests/e2e-ui/full/index-detail_analytics.spec.ts`, `web/src/routes/console/indexes/[name]/tabs/AnalyticsTab.svelte`.
    2. Add local `/console/migrate` coverage. Effort `S`. Suggested gate `post-L7`. Owner files seed: `web/tests/e2e-ui/full/migration-recovery.spec.ts`, `web/src/routes/console/migrate/+page.svelte`.

    ## Out Of Scope
    """
)

MALFORMED_FIXTURE = textwrap.dedent(
    """\
    # malformed summary

    ## Prioritized recommendations

    1. Fix signup error states and API key visibility with docs update. Priority = P0. Effort M. Owner files seed: `web/src/routes/(public)/signup/+page.svelte`, `infra/api/src/routes/public/signup.rs`.
    2. Improve search settings notes. Priority: P2. Effort band: L. Suggested gate between L6/L7. Owner files seed: `web/src/routes/console/indexes/[name]/tabs/SettingsTab.svelte` and `infra/billing/src/invoices.rs`.
    """
)

NO_SECTION_FIXTURE = textwrap.dedent(
    """\
    # no recommendations section

    ## Scope
    nothing to parse
    """
)


class ParseAuditRecommendationsTests(unittest.TestCase):
    def _write_temp_summary(self, body: str) -> Path:
        handle = tempfile.NamedTemporaryFile("w", suffix="_SUMMARY.md", delete=False)
        handle.write(body)
        handle.flush()
        handle.close()
        return Path(handle.name)

    def test_parses_multiline_and_single_line_formats(self) -> None:
        parity_path = self._write_temp_summary(PARITY_FIXTURE)
        coverage_path = self._write_temp_summary(COVERAGE_FIXTURE)

        parsed = parse_recommendation_sources(parity_path, coverage_path)
        rows = parsed["rows"]
        self.assertEqual(len(rows), 4)

        first = rows[0]
        self.assertEqual(first["priority"], "P0")
        self.assertEqual(first["gate"], "pre-L6")
        self.assertEqual(first["effort_band"], "M")
        self.assertEqual(first["title"], "Implement demo-index-loader in console create-index flow")
        self.assertEqual(
            first["owner_files"],
            [
                "web/src/routes/console/indexes/+page.svelte",
                "web/src/routes/console/indexes/+page.server.ts",
            ],
        )
        self.assertIn("source_path", first)
        self.assertIn("source_type", first)

        coverage_row = rows[2]
        self.assertEqual(coverage_row["effort_band"], "M")
        self.assertEqual(coverage_row["gate"], "post-L7")
        self.assertEqual(coverage_row["priority"], None)

    def test_prose_tolerant_fields_and_missing_gate_boundaries(self) -> None:
        parity_path = self._write_temp_summary(MALFORMED_FIXTURE)
        coverage_path = self._write_temp_summary(COVERAGE_FIXTURE)

        parsed = parse_recommendation_sources(parity_path, coverage_path)
        rows = parsed["rows"]
        missing_gate = rows[0]
        self.assertEqual(missing_gate["priority"], "P0")
        self.assertEqual(missing_gate["gate"], None)
        self.assertEqual(missing_gate["effort_band"], "M")
        self.assertEqual(
            missing_gate["owner_files"],
            [
                "web/src/routes/(public)/signup/+page.svelte",
                "infra/api/src/routes/public/signup.rs",
            ],
        )

        multi_owner = rows[1]
        self.assertEqual(multi_owner["gate"], "between L6/L7")
        self.assertEqual(
            multi_owner["owner_files"],
            [
                "web/src/routes/console/indexes/[name]/tabs/SettingsTab.svelte",
                "infra/billing/src/invoices.rs",
            ],
        )

    def test_missing_recommendations_section_records_parse_status(self) -> None:
        parity_path = self._write_temp_summary(NO_SECTION_FIXTURE)
        coverage_path = self._write_temp_summary(COVERAGE_FIXTURE)

        parsed = parse_recommendation_sources(parity_path, coverage_path)
        sources = parsed["sources"]
        parity_source = sources[0]
        self.assertEqual(parity_source["section_found"], False)
        self.assertEqual(parity_source["parse_status"], "missing_prioritized_recommendations")
        self.assertEqual(parity_source["row_count"], 0)
        self.assertEqual(len(parsed["rows"]), 2)


if __name__ == "__main__":
    unittest.main()
