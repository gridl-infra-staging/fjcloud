#!/usr/bin/env python3
"""TDD coverage for Stage 4 deterministic lane-file authoring."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from author_lane_files import main


def _row(
    *,
    source_path: str,
    source_type: str,
    source_row_number: int,
    row_order: int,
    title: str,
    body: str,
    owner_files: list[str],
) -> dict[str, object]:
    return {
        "source_path": source_path,
        "source_type": source_type,
        "source_row_number": source_row_number,
        "row_order": row_order,
        "title": title,
        "body": body,
        "priority": "P0",
        "gate": "pre-L6",
        "effort_band": "M",
        "owner_files": owner_files,
        "launch_blocking": True,
    }


class AuthorLaneFilesTests(unittest.TestCase):
    def test_authors_stable_files_with_required_sections_and_bijective_index(self) -> None:
        rows = [
            _row(
                source_path="docs/audits/feature-parity/20260524T174411Z_fjcloud_vs_engine_dashboard/SUMMARY.md",
                source_type="parity",
                source_row_number=7,
                row_order=2,
                title="Protect Billing Portal Session Creation",
                body="Priority: P0\nOwner-files seed: `infra/api/src/routes/customer/billing.rs`",
                owner_files=[
                    "infra/api/src/routes/customer/billing.rs",
                    "web/src/lib/billing/client.ts",
                ],
            ),
            _row(
                source_path="docs/audits/test-coverage/20260524T185319Z_console_index_tabs/SUMMARY.md",
                source_type="coverage",
                source_row_number=2,
                row_order=1,
                title="Implement demo-index-loader in console create-index flow",
                body="Priority: P0\nOwner-files seed: `web/src/routes/console/indexes/+page.svelte`",
                owner_files=[
                    "web/src/routes/console/indexes/+page.svelte",
                    "web/src/routes/console/indexes/+page.server.ts",
                ],
            ),
        ]

        payload = {"sources": [], "metadata": {"row_count": 2}, "rows": rows}

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            triage_dir = root / "docs" / "audits" / "triage" / "20260524T202244Z"
            output_dir = root / "chats" / "icg"
            triage_dir.mkdir(parents=True, exist_ok=True)
            output_dir.mkdir(parents=True, exist_ok=True)

            to_author_path = triage_dir / "to_author.json"
            to_author_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

            exit_code = main(["author_lane_files.py", str(to_author_path), str(output_dir)])
            self.assertEqual(exit_code, 0)

            lane_paths = sorted(output_dir.glob("may24_20260524T202244Z_w3_*.md"))
            self.assertEqual(len(lane_paths), 2)
            self.assertEqual(
                [path.name for path in lane_paths],
                [
                    "may24_20260524T202244Z_w3_1_protect_billing_portal_session_creation.md",
                    "may24_20260524T202244Z_w3_2_implement_demo_index_loader_in.md",
                ],
            )

            first_lane = lane_paths[0].read_text(encoding="utf-8")
            self.assertIn("# may24 20260524T202244Z — W3.1 Protect Billing Portal Session Creation", first_lane)
            self.assertIn("## PURPOSE", first_lane)
            self.assertIn("## Out of scope", first_lane)
            self.assertIn("## Stage 1", first_lane)
            self.assertIn("## Stage 2", first_lane)
            self.assertIn("## Stage 3", first_lane)
            self.assertIn("## Merge plan", first_lane)
            self.assertIn(rows[0]["body"], first_lane)
            self.assertIn("infra/api/src/routes/customer/billing.rs", first_lane)
            self.assertIn("web/src/lib/billing/client.ts", first_lane)
            self.assertIn(
                "source SUMMARY row = `docs/audits/feature-parity/20260524T174411Z_fjcloud_vs_engine_dashboard/SUMMARY.md:row-7`",
                first_lane,
            )

            second_lane = lane_paths[1].read_text(encoding="utf-8")
            self.assertIn("web/src/routes/console/indexes/+page.svelte", second_lane)
            self.assertIn("web/src/routes/console/indexes/+page.server.ts", second_lane)

            index_path = output_dir / "may24_20260524T202244Z_w3_index.json"
            self.assertTrue(index_path.exists())
            index_payload = json.loads(index_path.read_text(encoding="utf-8"))
            entries = index_payload["entries"]
            self.assertEqual(len(entries), 2)

            indexed_paths = [entry["path"] for entry in entries]
            self.assertEqual(
                indexed_paths,
                [
                    "chats/icg/may24_20260524T202244Z_w3_1_protect_billing_portal_session_creation.md",
                    "chats/icg/may24_20260524T202244Z_w3_2_implement_demo_index_loader_in.md",
                ],
            )

            mapped_keys = {
                (entry["source_path"], entry["source_row_number"], entry["title"])
                for entry in entries
            }
            self.assertEqual(
                mapped_keys,
                {
                    (
                        rows[0]["source_path"],
                        rows[0]["source_row_number"],
                        rows[0]["title"],
                    ),
                    (
                        rows[1]["source_path"],
                        rows[1]["source_row_number"],
                        rows[1]["title"],
                    ),
                },
            )

            self.assertEqual(len(mapped_keys), len(rows))


if __name__ == "__main__":
    unittest.main()
