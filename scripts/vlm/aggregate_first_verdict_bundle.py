#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

SEVERITY_RANK = {"BLOCKER": 4, "EMBARRASSING": 3, "HARDENING": 2, "MAINT": 1}
CRITICAL_PATH_ROUTES = {
    "/",
    "/pricing",
    "/signup",
    "/login",
    "/dashboard",
    "/dashboard/billing",
    "/dashboard/billing/setup",
}
NULL_RULE_ID_WARNING_THRESHOLD = 0.30


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-path", required=True)
    parser.add_argument("--judgments-dir", required=True)
    parser.add_argument("--postmortems-path", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bundle-relative-path", required=True)
    parser.add_argument("--cost-log-path", required=True)
    parser.add_argument("--uncovered-json-path", required=False, default="")
    parser.add_argument("--max-cost-usd", type=float, required=False, default=5.0)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_postmortem_rule_severity(path: Path) -> dict[str, str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    mapping: dict[str, str] = {}
    current_rule_id = ""
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("**ID:**"):
            current_rule_id = stripped.replace("**ID:**", "", 1).strip()
            continue
        if stripped.startswith("**Severity:**") and current_rule_id:
            severity = stripped.replace("**Severity:**", "", 1).strip()
            if severity in SEVERITY_RANK:
                mapping[current_rule_id] = severity
            current_rule_id = ""
    return mapping


def severity_for_violation(
    verdict: str, rule_id: str | None, route_path: str, postmortem_rules: dict[str, str]
) -> tuple[str, str]:
    if verdict == "advisory":
        return ("HARDENING", "Rule 1")
    if rule_id and rule_id in postmortem_rules:
        return (postmortem_rules[rule_id], "Rule 2")
    if rule_id and (rule_id.startswith("M.") or rule_id.startswith("manifesto.")):
        return ("EMBARRASSING", "Rule 3")
    if verdict == "fail":
        if route_path in CRITICAL_PATH_ROUTES:
            return ("BLOCKER", "Rule 4")
        return ("EMBARRASSING", "Rule 4")
    return ("MAINT", "Rule 4")


def load_cost_totals(path: Path) -> tuple[int, int, float]:
    if not path.exists():
        return (0, 0, 0.0)
    input_tokens = 0
    output_tokens = 0
    total_cost = 0.0
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        record = json.loads(line)
        input_tokens += int(record.get("input_tokens", 0) or 0)
        output_tokens += int(record.get("output_tokens", 0) or 0)
        total_cost += float(record.get("estimated_request_cost_usd", 0) or 0)
    return (input_tokens, output_tokens, total_cost)


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest_path)
    judgments_dir = Path(args.judgments_dir)
    postmortems_path = Path(args.postmortems_path)
    output_path = Path(args.output)
    uncovered_json_path = Path(args.uncovered_json_path) if args.uncovered_json_path else None

    manifest = load_json(manifest_path)
    entries = list(manifest.get("entries", []))
    postmortem_rules = load_postmortem_rule_severity(postmortems_path)

    severity_rows: dict[str, list[str]] = {
        "BLOCKER": [],
        "EMBARRASSING": [],
        "HARDENING": [],
        "MAINT": [],
    }
    all_clear_rows: list[str] = []

    total_violations = 0
    null_rule_id_violations = 0

    for entry in entries:
        if not entry.get("is_producible"):
            continue
        artifact_filename = entry["artifact_filename"]
        route_path = entry["path"]
        state = entry["state"]
        viewport = entry["viewport"]
        judgment_path = judgments_dir / artifact_filename.replace(".png", ".json")
        if not judgment_path.exists():
            continue

        payload = load_json(judgment_path)
        verdict = str(payload.get("verdict", ""))
        violations = payload.get("violations", [])
        if not isinstance(violations, list):
            violations = []

        if verdict == "pass" and not violations:
            all_clear_rows.append(f"- {route_path} — {state} @ {viewport}")
            continue

        tuple_severity = "MAINT"
        finding_chunks: list[str] = []
        for index, violation in enumerate(violations):
            if not isinstance(violation, dict):
                continue
            total_violations += 1
            rule_id_value = violation.get("rule_id")
            if rule_id_value in (None, ""):
                null_rule_id_violations += 1
                normalized_rule_id: str | None = None
            else:
                normalized_rule_id = str(rule_id_value)
            severity, rule_branch = severity_for_violation(
                verdict, normalized_rule_id, route_path, postmortem_rules
            )
            if SEVERITY_RANK[severity] > SEVERITY_RANK[tuple_severity]:
                tuple_severity = severity
            pointer = f"{args.bundle_relative_path}/judgments/{judgment_path.name}#/violations/{index}"
            summary_text = str(violation.get("description", "")).strip()
            finding_chunks.append(
                f"{pointer} ({rule_branch}, rule_id={normalized_rule_id or 'null'}: {summary_text})"
            )

        if not finding_chunks:
            all_clear_rows.append(f"- {route_path} — {state} @ {viewport}")
            continue

        summary = str(payload.get("summary", "")).strip()
        severity_rows[tuple_severity].append(
            f"- [ ] route={route_path} state={state} viewport={viewport} — {summary} — "
            + "; ".join(finding_chunks)
        )

    uncovered_rows: list[str] = []
    if uncovered_json_path and uncovered_json_path.exists():
        for item in load_json(uncovered_json_path):
            uncovered_rows.append(
                "- route={path} state={state} viewport={viewport} reason={reason}".format(
                    path=item.get("path", ""),
                    state=item.get("state", ""),
                    viewport=item.get("viewport", ""),
                    reason=item.get("reason", ""),
                )
            )

    input_tokens, output_tokens, total_cost = load_cost_totals(Path(args.cost_log_path))
    if total_cost > args.max_cost_usd:
        raise SystemExit(
            f"Total cost {total_cost:.8f} exceeds configured cap {args.max_cost_usd:.8f}"
        )

    null_ratio = (null_rule_id_violations / total_violations) if total_violations else 0.0
    null_warning = (
        f"WARNING: null-rule-id ratio is {null_ratio:.2%} ({null_rule_id_violations}/{total_violations})"
        if total_violations and null_ratio > NULL_RULE_ID_WARNING_THRESHOLD
        else "null-rule-id ratio is within threshold"
    )

    lines: list[str] = [
        "# Stream C input — VLM verdict findings",
        "",
        f"**Bundle:** {args.bundle_relative_path}",
        "",
        "### BLOCKER",
    ]
    lines.extend(severity_rows["BLOCKER"] or ["- [ ] none"])
    lines.extend(["", "### EMBARRASSING"])
    lines.extend(severity_rows["EMBARRASSING"] or ["- [ ] none"])
    lines.extend(["", "### HARDENING"])
    lines.extend(severity_rows["HARDENING"] or ["- [ ] none"])
    lines.extend(["", "### MAINT"])
    lines.extend(severity_rows["MAINT"] or ["- [ ] none"])
    lines.extend(["", "## All-clear lanes"])
    lines.extend(all_clear_rows or ["- none"])
    lines.extend(["", "## Uncovered tuples"])
    lines.extend(uncovered_rows or ["- none"])
    lines.extend(
        [
            "",
            "## Cost ledger",
            f"- total input tokens: {input_tokens}",
            f"- total output tokens: {output_tokens}",
            f"- total cost usd: {total_cost:.8f}",
            f"- configured max cost usd: {args.max_cost_usd:.8f}",
            f"- {null_warning}",
        ]
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
