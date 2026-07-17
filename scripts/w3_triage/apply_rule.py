#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

PRE_CUTOVER_GATES = {"pre-l6", "pre-w4-cutover"}
CUSTOMER_VISIBLE_OWNER_PREFIXES = (
    "web/src/routes/console/",
    "web/src/routes/(public)/",
    "web/src/routes/+page.svelte",
    "infra/api/src/routes/customer/",
    "infra/api/src/routes/public/",
    "infra/api/src/routes/webhooks/",
    "infra/billing/",
    "web/src/lib/billing/",
)
CUSTOMER_VISIBLE_TOKEN_RE = re.compile(
    r"signup|signin|login|billing|invoice|payment|password|email|api[- ]?key|"
    r"cancel|portal|index|search|migrate|upload|demo|onboard|trial",
    re.IGNORECASE,
)
BILLINGPLAN_OVERRIDE_REQUIRED_TOKENS = ("billingplan", "shared", "paid", "rename")
BILLINGPLAN_REASON = (
    "BillingPlan::Shared → Paid Rust rename: internal storage seam; "
    "Lane 3 already shipped customer-facing UI label; "
    "rule 3 fails (not customer-visible)"
)
DEMO_TITLE = "Implement demo index loader in console flow"
DEMO_FALLBACK_OWNER = "web/src/lib/demo-indexes/"


def _row_identity(row: dict[str, Any]) -> tuple[Any, Any, Any]:
    return (row.get("source_path"), row.get("source_row_number"), row.get("title"))


def _row_sort_key(row: dict[str, Any]) -> tuple[Any, Any, Any, Any]:
    return (
        str(row.get("source_path") or ""),
        int(row.get("source_row_number") or 0),
        int(row.get("row_order") or 0),
        str(row.get("title") or ""),
    )


def _normalize_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip().lower()


def _is_pre_cutover_gate(gate: Any) -> bool:
    return _normalize_text(gate) in PRE_CUTOVER_GATES


def _has_customer_visible_owner(owner_files: Any) -> bool:
    if not isinstance(owner_files, list):
        return False

    for owner_path in owner_files:
        normalized = str(owner_path).strip()
        if any(normalized.startswith(prefix) for prefix in CUSTOMER_VISIBLE_OWNER_PREFIXES):
            return True
    return False


def _has_customer_visible_text(row: dict[str, Any]) -> bool:
    text = f"{row.get('title', '')}\n{row.get('body', '')}"
    return CUSTOMER_VISIBLE_TOKEN_RE.search(text) is not None


def _is_customer_visible(row: dict[str, Any]) -> bool:
    return _has_customer_visible_owner(row.get("owner_files")) or _has_customer_visible_text(row)


def _evaluate_row(row: dict[str, Any]) -> dict[str, Any]:
    priority_match = _normalize_text(row.get("priority")) == "p0"
    gate_match = _is_pre_cutover_gate(row.get("gate"))
    customer_visible = _is_customer_visible(row)
    return {
        "priority_match": priority_match,
        "gate_match": gate_match,
        "customer_visible": customer_visible,
        "launch_blocking": priority_match and gate_match and customer_visible,
    }


def _is_demo_override_candidate(row: dict[str, Any]) -> bool:
    title = _normalize_text(row.get("title"))
    if "demo" not in title or ("loader" not in title and "index" not in title):
        return False

    owner_files = row.get("owner_files")
    if not isinstance(owner_files, list):
        return False

    for owner_path in owner_files:
        normalized = str(owner_path).strip()
        if normalized.startswith("web/src/routes/console/indexes/"):
            return True
        if normalized.startswith("web/src/lib/demo-indexes/"):
            return True
    return False


def _is_named_demo_ask(row: dict[str, Any]) -> bool:
    return _normalize_text(row.get("title")) == _normalize_text(DEMO_TITLE)


def _is_billingplan_override(row: dict[str, Any]) -> bool:
    text = _normalize_text(f"{row.get('title', '')}\n{row.get('body', '')}")
    return all(token in text for token in BILLINGPLAN_OVERRIDE_REQUIRED_TOKENS)


def _source_warnings(sources: Any) -> list[dict[str, Any]]:
    if not isinstance(sources, list):
        return []

    warnings: list[dict[str, Any]] = []
    for source in sources:
        if not isinstance(source, dict):
            continue
        if source.get("parse_status") == "ok":
            continue

        warnings.append(
            {
                "source_path": source.get("source_path"),
                "source_type": source.get("source_type"),
                "parse_status": source.get("parse_status"),
                "row_count": source.get("row_count"),
            }
        )
    return warnings


def _discover_demo_owner_files() -> list[str]:
    cmd = [
        "rg",
        "-n",
        "-l",
        "demo",
        "web/src/lib",
        "web/src/routes/console",
        "infra/api/src",
    ]
    try:
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return []

    if result.returncode not in (0, 1):
        return []

    seen: set[str] = set()
    discovered: list[str] = []
    for line in result.stdout.splitlines():
        value = line.strip()
        if not value or value in seen:
            continue
        seen.add(value)
        discovered.append(value)

    discovered.sort()
    return discovered[:10]


def _build_demo_row(demo_owner_files_seed: list[str]) -> dict[str, Any]:
    owners = demo_owner_files_seed or [DEMO_FALLBACK_OWNER]
    return {
        "source_path": "standing_inclusion",
        "source_type": "standing_inclusion",
        "source_row_number": 0,
        "row_order": 0,
        "title": DEMO_TITLE,
        "body": "Standing inclusion from W3 policy: include demo-index loader lane.",
        "priority": "P0",
        "gate": "pre-W4-cutover",
        "effort_band": "M",
        "owner_files": owners,
        "standing_inclusion": True,
        "standing_inclusion_reason": "named_ask_demo_index_loader",
        "launch_blocking": True,
        "rule_evaluation": {
            "priority_match": True,
            "gate_match": True,
            "customer_visible": True,
            "launch_blocking": True,
            "rule_override": "standing_demo_loader",
        },
    }


def _build_forced_billing_row(matched_row: dict[str, Any] | None) -> dict[str, Any]:
    forced_row = {
        "source_path": "standing_exclusion",
        "source_type": "standing_exclusion",
        "source_row_number": 0,
        "row_order": 0,
        "title": "BillingPlan::Shared to Paid Rust rename",
        "body": BILLINGPLAN_REASON,
        "priority": None,
        "gate": None,
        "effort_band": "M",
        "owner_files": ["infra/billing/"],
        "forced_defer": True,
        "defer_reason_code": "billingplan_rename_internal_storage",
        "defer_reason": BILLINGPLAN_REASON,
        "launch_blocking": False,
        "rule_evaluation": {
            "priority_match": False,
            "gate_match": False,
            "customer_visible": False,
            "launch_blocking": False,
            "rule_override": "forced_billingplan_defer",
        },
    }
    if matched_row is not None:
        forced_row["matched_input_row"] = {
            "source_path": matched_row.get("source_path"),
            "source_row_number": matched_row.get("source_row_number"),
            "title": matched_row.get("title"),
        }
    return forced_row


def _finalize_output(
    rows: list[dict[str, Any]],
    sources: list[dict[str, Any]],
    warnings: list[dict[str, Any]],
) -> dict[str, Any]:
    sorted_rows = sorted(rows, key=_row_sort_key)
    return {
        "sources": sources,
        "metadata": {
            "source_warnings": warnings,
            "source_warning_count": len(warnings),
            "row_count": len(sorted_rows),
        },
        "rows": sorted_rows,
    }


def apply_rules(
    recommendations: dict[str, Any],
    demo_owner_files_seed: list[str] | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    sources = recommendations.get("sources")
    rows = recommendations.get("rows")
    if not isinstance(sources, list):
        raise ValueError("recommendations sources must be a list")
    if not isinstance(rows, list):
        raise ValueError("recommendations rows must be a list")

    canonical_rows = [copy.deepcopy(r) for r in rows if isinstance(r, dict)]
    canonical_rows.sort(key=_row_sort_key)

    demo_candidates: list[dict[str, Any]] = []
    billing_match: dict[str, Any] | None = None
    excluded_ids: set[tuple[Any, Any, Any]] = set()
    adopted_demo_identity: tuple[Any, Any, Any] | None = None

    for row in canonical_rows:
        if _is_demo_override_candidate(row):
            demo_candidates.append(row)
        if _is_billingplan_override(row):
            excluded_ids.add(_row_identity(row))
            if billing_match is None:
                billing_match = row

    named_demo_candidates = [row for row in demo_candidates if _is_named_demo_ask(row)]
    if named_demo_candidates:
        # Collapse every exact-title named demo ask into the single standing-override
        # row. Excluding only the first copy would let duplicate copies of the same
        # canonical ask (e.g. one per audit source) flow through normal partitioning
        # and reappear in to_author/to_defer. Distinct non-canonical demo/index rows
        # have different titles, are not in named_demo_candidates, and still partition.
        for candidate in named_demo_candidates:
            excluded_ids.add(_row_identity(candidate))
        adopted_demo_identity = _row_identity(named_demo_candidates[0])
    elif demo_candidates:
        adopted_demo_identity = _row_identity(demo_candidates[0])
        excluded_ids.add(adopted_demo_identity)

    to_author_rows: list[dict[str, Any]] = []
    to_defer_rows: list[dict[str, Any]] = []

    for row in canonical_rows:
        if _row_identity(row) in excluded_ids:
            continue

        evaluation = _evaluate_row(row)
        row["rule_evaluation"] = evaluation
        row["launch_blocking"] = evaluation["launch_blocking"]

        if evaluation["launch_blocking"]:
            to_author_rows.append(row)
        else:
            to_defer_rows.append(row)

    if adopted_demo_identity is not None:
        adopted_demo_source = next(
            row for row in canonical_rows if _row_identity(row) == adopted_demo_identity
        )
        adopted_demo = copy.deepcopy(adopted_demo_source)
        adopted_demo["standing_override_applied"] = True
        adopted_demo["standing_override_reason"] = "named_ask_demo_index_loader"
        adopted_demo["launch_blocking"] = True
        adopted_demo["rule_evaluation"] = {
            "priority_match": _normalize_text(adopted_demo.get("priority")) == "p0",
            "gate_match": _is_pre_cutover_gate(adopted_demo.get("gate")),
            "customer_visible": _is_customer_visible(adopted_demo),
            "launch_blocking": True,
            "rule_override": "standing_demo_loader",
        }
        to_author_rows.append(adopted_demo)
    else:
        seed = demo_owner_files_seed
        if seed is None:
            seed = _discover_demo_owner_files()
        to_author_rows.append(_build_demo_row(seed))

    to_defer_rows.append(_build_forced_billing_row(billing_match))

    warnings = _source_warnings(sources)
    author_output = _finalize_output(to_author_rows, sources, warnings)
    defer_output = _finalize_output(to_defer_rows, sources, warnings)
    return author_output, defer_output


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: python3 scripts/w3_triage/apply_rule.py "
            "<recommendations_json> <triage_dir>",
            file=sys.stderr,
        )
        return 2

    input_path = Path(argv[1])
    triage_dir = Path(argv[2])

    recommendations = json.loads(input_path.read_text(encoding="utf-8"))
    to_author, to_defer = apply_rules(recommendations)

    triage_dir.mkdir(parents=True, exist_ok=True)
    (triage_dir / "to_author.json").write_text(
        json.dumps(to_author, indent=2) + "\n",
        encoding="utf-8",
    )
    (triage_dir / "to_defer.json").write_text(
        json.dumps(to_defer, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
