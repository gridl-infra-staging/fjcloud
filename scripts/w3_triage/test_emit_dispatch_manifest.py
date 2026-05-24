#!/usr/bin/env python3
"""TDD coverage for Stage 5 deterministic dispatch manifest emission."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from emit_dispatch_manifest import emit_dispatch_manifest, main


def _author_row(
    *,
    source_path: str,
    source_row_number: int,
    title: str,
    effort_band: str,
) -> dict[str, object]:
    return {
        "source_path": source_path,
        "source_row_number": source_row_number,
        "title": title,
        "effort_band": effort_band,
        "body": "row body",
    }


def _index_entry(
    *,
    lane_number: int,
    slug: str,
    title: str,
    source_path: str,
    source_row_number: int,
    ts: str,
) -> dict[str, object]:
    return {
        "lane_number": lane_number,
        "slug": slug,
        "title": title,
        "source_path": source_path,
        "source_row_number": source_row_number,
        "path": f"chats/icg/may24_{ts}_w3_{lane_number}_{slug}.md",
    }


class EmitDispatchManifestTests(unittest.TestCase):
    def test_orders_size_bands_by_s_m_l_xl_uses_index_order_and_chunks_to_four(self) -> None:
        ts = "20260524T202244Z"
        warnings = [
            {
                "source_path": "docs/audits/test-coverage/20260524T185319Z_console_index_tabs/SUMMARY.md",
                "source_type": "coverage",
                "parse_status": "missing_prioritized_recommendations",
                "row_count": 0,
            }
        ]

        rows = [
            _author_row(source_path="src/1.md", source_row_number=1, title="Zulu S1", effort_band="S"),
            _author_row(source_path="src/2.md", source_row_number=2, title="Alpha S2", effort_band="S"),
            _author_row(source_path="src/3.md", source_row_number=3, title="Bravo S3", effort_band="S"),
            _author_row(source_path="src/4.md", source_row_number=4, title="Charlie S4", effort_band="S"),
            _author_row(source_path="src/5.md", source_row_number=5, title="Delta S5", effort_band="S"),
            _author_row(source_path="src/6.md", source_row_number=6, title="Mike M1", effort_band="M"),
            _author_row(source_path="src/7.md", source_row_number=7, title="Lima L1", effort_band="L"),
            _author_row(source_path="src/8.md", source_row_number=8, title="Xray XL1", effort_band="XL"),
        ]

        index_entries = [
            _index_entry(lane_number=10, slug="zulu_s1", title="Zulu S1", source_path="src/1.md", source_row_number=1, ts=ts),
            _index_entry(lane_number=9, slug="alpha_s2", title="Alpha S2", source_path="src/2.md", source_row_number=2, ts=ts),
            _index_entry(lane_number=8, slug="bravo_s3", title="Bravo S3", source_path="src/3.md", source_row_number=3, ts=ts),
            _index_entry(lane_number=7, slug="charlie_s4", title="Charlie S4", source_path="src/4.md", source_row_number=4, ts=ts),
            _index_entry(lane_number=6, slug="delta_s5", title="Delta S5", source_path="src/5.md", source_row_number=5, ts=ts),
            _index_entry(lane_number=5, slug="mike_m1", title="Mike M1", source_path="src/6.md", source_row_number=6, ts=ts),
            _index_entry(lane_number=4, slug="lima_l1", title="Lima L1", source_path="src/7.md", source_row_number=7, ts=ts),
            _index_entry(lane_number=3, slug="xray_xl1", title="Xray XL1", source_path="src/8.md", source_row_number=8, ts=ts),
        ]

        to_defer_rows = [
            {
                "title": "BillingPlan::Shared to Paid Rust rename",
                "defer_reason": "forced defer reason",
                "source_path": "standing_exclusion",
                "source_row_number": 0,
            },
            {
                "title": "General deferred row",
                "defer_reason": "priority=P1",
                "source_path": "src/defer.md",
                "source_row_number": 9,
            },
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            triage_dir = root / "docs" / "audits" / "triage" / ts
            chats_dir = root / "chats" / "icg"
            triage_dir.mkdir(parents=True, exist_ok=True)
            chats_dir.mkdir(parents=True, exist_ok=True)

            to_author_path = triage_dir / "to_author.json"
            to_defer_path = triage_dir / "to_defer.json"
            index_path = chats_dir / f"may24_{ts}_w3_index.json"

            to_author_path.write_text(
                json.dumps(
                    {
                        "metadata": {
                            "source_warnings": warnings,
                            "source_warning_count": len(warnings),
                        },
                        "rows": rows,
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            to_defer_path.write_text(
                json.dumps(
                    {
                        "metadata": {
                            "source_warnings": warnings,
                            "source_warning_count": len(warnings),
                        },
                        "rows": to_defer_rows,
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            index_path.write_text(
                json.dumps({"ts": ts, "entries": index_entries}, indent=2) + "\n",
                encoding="utf-8",
            )

            manifest_path, shell_path = emit_dispatch_manifest(
                to_author_path=to_author_path,
                to_defer_path=to_defer_path,
                index_path=index_path,
                output_dir=chats_dir,
                emit_shell=True,
            )

            self.assertEqual(manifest_path.name, f"may24_{ts}_w3_dispatch.md")
            self.assertTrue(shell_path is not None)
            self.assertTrue(shell_path.exists())

            manifest = manifest_path.read_text(encoding="utf-8")

            # Band order and <=4 chunking: S first, split into 4 + 1, then M/L/XL.
            self.assertIn("### Sub-wave 1 - S - 4 lanes", manifest)
            self.assertIn("### Sub-wave 2 - S - 1 lane", manifest)
            self.assertIn("### Sub-wave 3 - M - 1 lane", manifest)
            self.assertIn("### Sub-wave 4 - L - 1 lane", manifest)
            self.assertIn("### Sub-wave 5 - XL - 1 lane", manifest)

            command_lines = [
                line.strip()
                for line in manifest.splitlines()
                if line.strip().startswith("- `batman /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/chats/icg/")
            ]
            expected_paths = [
                "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/chats/icg/"
                + entry["path"].removeprefix("chats/icg/")
                for entry in index_entries
            ]
            self.assertEqual(
                [line[len("- `batman ") : -1] for line in command_lines],
                expected_paths,
            )

            self.assertIn("## Deferred past announce", manifest)
            self.assertIn("BillingPlan::Shared to Paid Rust rename", manifest)
            self.assertIn("General deferred row", manifest)

            self.assertIn("## Blocked / requires upstream re-run", manifest)
            self.assertIn("missing_prioritized_recommendations", manifest)

            shell_commands = [
                line.strip()
                for line in shell_path.read_text(encoding="utf-8").splitlines()
                if line.strip().startswith("batman ")
            ]
            self.assertEqual(
                shell_commands,
                [f"batman {path}" for path in expected_paths],
            )

    def test_omits_blocked_section_when_no_source_warnings(self) -> None:
        ts = "20260524T202244Z"
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            triage_dir = root / "docs" / "audits" / "triage" / ts
            chats_dir = root / "chats" / "icg"
            triage_dir.mkdir(parents=True, exist_ok=True)
            chats_dir.mkdir(parents=True, exist_ok=True)

            to_author_path = triage_dir / "to_author.json"
            to_defer_path = triage_dir / "to_defer.json"
            index_path = chats_dir / f"may24_{ts}_w3_index.json"

            to_author_path.write_text(
                json.dumps(
                    {
                        "metadata": {"source_warnings": [], "source_warning_count": 0},
                        "rows": [
                            _author_row(
                                source_path="src/1.md",
                                source_row_number=1,
                                title="Only lane",
                                effort_band="M",
                            )
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            to_defer_path.write_text(
                json.dumps(
                    {
                        "metadata": {"source_warnings": [], "source_warning_count": 0},
                        "rows": [],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            index_path.write_text(
                json.dumps(
                    {
                        "ts": ts,
                        "entries": [
                            _index_entry(
                                lane_number=1,
                                slug="only_lane",
                                title="Only lane",
                                source_path="src/1.md",
                                source_row_number=1,
                                ts=ts,
                            )
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            exit_code = main(
                [
                    "emit_dispatch_manifest.py",
                    str(to_author_path),
                    str(to_defer_path),
                    str(index_path),
                ]
            )
            self.assertEqual(exit_code, 0)

            manifest_path = chats_dir / f"may24_{ts}_w3_dispatch.md"
            manifest = manifest_path.read_text(encoding="utf-8")
            self.assertNotIn("## Blocked / requires upstream re-run", manifest)


if __name__ == "__main__":
    unittest.main()
