import importlib.util
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "extract_pricing_evidence_text.py"
PRICING_EVIDENCE_PATH = (
    REPO_ROOT
    / "docs"
    / "runbooks"
    / "evidence"
    / "pricing-verification"
    / "20260729T170845Z"
)
AUDITED_STAGE_2_HEAD = "71adc2c29ecf22e11425f1a7f58328eb600ac8ea"


class ExtractPricingEvidenceTextTest(unittest.TestCase):
    def load_module(self):
        spec = importlib.util.spec_from_file_location(
            "extract_pricing_evidence_text",
            MODULE_PATH,
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_visible_text_excludes_script_and_decodes_entities(self):
        module = self.load_module()

        text = module.extract_visible_text(
            """
            <html>
              <head>
                <style>.price { display: none; }</style>
                <script>const hidden = "$0.001";</script>
              </head>
              <body>
                <h1>Standard &amp; Production</h1>
                <p>$99 / month</p>
                <div>120&nbsp;GB across 2 availability zones</div>
              </body>
            </html>
            """
        )

        self.assertIn("Standard & Production", text)
        self.assertIn("$99 / month", text)
        self.assertIn("120 GB across 2 availability zones", text)
        self.assertNotIn("$0.001", text)
        self.assertNotIn("display: none", text)

    def test_typesense_evidence_search_covers_all_modeled_values(self):
        evidence_path = PRICING_EVIDENCE_PATH / "typesense_cloud.md"

        evidence = evidence_path.read_text(encoding="utf-8")
        command = re.search(
            r"Evidence extraction command:\n\n```bash\n(?P<command>.*?)\n```",
            evidence,
            re.DOTALL,
        ).group("command")

        for required_value in (
            "1 GB",
            "2 GB",
            "4 GB",
            "8 GB",
            "16 GB",
            "32 GB",
            "64 GB",
            "\\$0\\.054",
            "\\$0\\.10",
            "\\$0\\.19",
            "\\$0\\.38",
            "\\$0\\.74",
            "\\$1\\.39",
            "\\$2\\.46",
        ):
            self.assertIn(required_value, command)

    def test_pricing_evidence_provenance_pins_audited_stage_2_commit(self):
        summary = (PRICING_EVIDENCE_PATH / "SUMMARY.md").read_text(encoding="utf-8")
        head_sha = (PRICING_EVIDENCE_PATH / "head_sha.txt").read_text(
            encoding="utf-8"
        ).strip()

        self.assertEqual(AUDITED_STAGE_2_HEAD, head_sha)
        self.assertIn(f"HEAD: {AUDITED_STAGE_2_HEAD}", summary)


if __name__ == "__main__":
    unittest.main(verbosity=2)
