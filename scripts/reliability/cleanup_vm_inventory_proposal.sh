#!/usr/bin/env bash
# cleanup_vm_inventory_proposal.sh
#
# Offline-only renderer that reads a frozen Stage 1 evidence bundle and prints
# reviewable SQL candidates. This script intentionally avoids live lookups so
# proposal output is deterministic for one captured evidence directory.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  cleanup_vm_inventory_proposal.sh --evidence-dir <dir>

Required evidence files under <dir>:
  inventory_rows.json
  deployment_rows.json
  reconciliation_summary.json
  vm_inventory_status_counts.csv
  customer_deployments_status_counts.csv
  provisioning_age_distribution.csv
  provisioning_rows_detailed.csv
  provisioning_by_customer_cohort.csv
  billing_accuracy_impact.csv

Optional evidence file:
  ec2_instances.json

Exit contract:
  0 => SQL proposals rendered successfully
  2 => usage error or missing/invalid evidence contract
USAGE
}

system_error() {
    echo "ERROR: $*" >&2
    exit 2
}

EVIDENCE_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --evidence-dir)
            [ "$#" -ge 2 ] || system_error "--evidence-dir requires a value"
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$EVIDENCE_DIR" ] || system_error "--evidence-dir is required"
[ -d "$EVIDENCE_DIR" ] || system_error "evidence directory not found: $EVIDENCE_DIR"

required_files=(
    "inventory_rows.json"
    "deployment_rows.json"
    "reconciliation_summary.json"
    "vm_inventory_status_counts.csv"
    "customer_deployments_status_counts.csv"
    "provisioning_age_distribution.csv"
    "provisioning_rows_detailed.csv"
    "provisioning_by_customer_cohort.csv"
    "billing_accuracy_impact.csv"
)

for required_file in "${required_files[@]}"; do
    if [ ! -f "$EVIDENCE_DIR/$required_file" ]; then
        system_error "missing required artifact: $required_file"
    fi
done

EC2_JSON_PATH=""
if [ -f "$EVIDENCE_DIR/ec2_instances.json" ]; then
    EC2_JSON_PATH="$EVIDENCE_DIR/ec2_instances.json"
fi

if ! python3 - \
    "$EVIDENCE_DIR/reconciliation_summary.json" \
    "$EVIDENCE_DIR/inventory_rows.json" \
    "$EVIDENCE_DIR/deployment_rows.json" \
    "$EC2_JSON_PATH" \
    "$EVIDENCE_DIR/vm_inventory_status_counts.csv" \
    "$EVIDENCE_DIR/customer_deployments_status_counts.csv" \
    "$EVIDENCE_DIR/provisioning_age_distribution.csv" \
    "$EVIDENCE_DIR/provisioning_rows_detailed.csv" \
    "$EVIDENCE_DIR/provisioning_by_customer_cohort.csv" \
    "$EVIDENCE_DIR/billing_accuracy_impact.csv" <<'PY'
import csv
import json
import sys
from pathlib import Path

(
    reconciliation_path,
    inventory_path,
    deployment_path,
    ec2_path,
    vm_inventory_status_counts_path,
    customer_deployments_status_counts_path,
    provisioning_age_distribution_path,
    provisioning_rows_detailed_path,
    provisioning_by_customer_cohort_path,
    billing_accuracy_impact_path,
) = sys.argv[1:]


def load_json(path: str, label: str, expected_kind: str):
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if expected_kind == "object" and not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object")
    if expected_kind == "array" and not isinstance(payload, list):
        raise ValueError(f"{label} must be a JSON array")
    return payload


def load_csv(path: str, label: str):
    with Path(path).open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"{label} must include a CSV header")
        return list(reader)


def to_int(value) -> int:
    if value is None:
        return 0
    text = str(value).strip()
    if text == "":
        return 0
    return int(text)


def sql_quote(raw_value) -> str:
    if raw_value is None:
        return "NULL"
    text = str(raw_value).replace("'", "''")
    return f"'{text}'"


reconciliation_summary = load_json(reconciliation_path, "reconciliation_summary.json", "object")
inventory_rows = load_json(inventory_path, "inventory_rows.json", "array")
deployment_rows = load_json(deployment_path, "deployment_rows.json", "array")
ec2_rows = []
if ec2_path:
    ec2_rows = load_json(ec2_path, "ec2_instances.json", "array")

vm_inventory_status_counts = load_csv(vm_inventory_status_counts_path, "vm_inventory_status_counts.csv")
customer_deployments_status_counts = load_csv(
    customer_deployments_status_counts_path,
    "customer_deployments_status_counts.csv",
)
provisioning_age_distribution = load_csv(
    provisioning_age_distribution_path,
    "provisioning_age_distribution.csv",
)
provisioning_rows_detailed = load_csv(
    provisioning_rows_detailed_path,
    "provisioning_rows_detailed.csv",
)
provisioning_by_customer_cohort = load_csv(
    provisioning_by_customer_cohort_path,
    "provisioning_by_customer_cohort.csv",
)
billing_accuracy_impact = load_csv(
    billing_accuracy_impact_path,
    "billing_accuracy_impact.csv",
)

raw_records = reconciliation_summary.get("raw_records", {})
inventory_drift_rows = raw_records.get("inventory_rows_without_nonterminated_ec2_match", [])
shared_ec2_without_inventory_rows = raw_records.get("managed_instances_without_inventory_match", [])
stuck_provisioning_rows = raw_records.get("stuck_shared_provisioning_rows", [])

lines: list[str] = []
lines.append("BEGIN;")
lines.append("-- Proposal-only output: render from frozen evidence inputs, do not execute in this script.")
lines.append(
    "-- Input snapshot sizes: "
    f"inventory_rows={len(inventory_rows)}, "
    f"deployment_rows={len(deployment_rows)}, "
    f"ec2_rows={len(ec2_rows)}"
)
lines.append("")

lines.append("-- Evidence bucket: reconciliation inventory rows missing EC2 backing")
if inventory_drift_rows:
    for row in inventory_drift_rows:
        vm_inventory_id = row.get("vm_inventory_id")
        hostname = row.get("hostname", "unknown-host")
        lines.append(f"-- candidate source: {hostname}")
        lines.append(
            "UPDATE vm_inventory SET status = 'error' "
            f"WHERE id = {sql_quote(vm_inventory_id)}::uuid AND status = 'active';"
        )
else:
    lines.append("-- no-op: reconciliation summary reports zero rows in this bucket")
lines.append("")

lines.append("-- Evidence bucket: shared EC2 instances missing inventory rows")
if shared_ec2_without_inventory_rows:
    for row in shared_ec2_without_inventory_rows:
        instance_id = row.get("instance_id")
        hostname = row.get("hostname")
        lines.append(
            "SELECT "
            f"{sql_quote(instance_id)} AS instance_id, "
            f"{sql_quote(hostname)} AS hostname, "
            "'missing_inventory_row' AS review_reason;"
        )
else:
    lines.append("-- no-op: reconciliation summary reports zero shared EC2 orphan rows")
lines.append("")

lines.append("-- Evidence bucket: aged provisioning backlog")
if stuck_provisioning_rows:
    for row in stuck_provisioning_rows:
        deployment_id = row.get("deployment_id")
        lines.append(
            "UPDATE customer_deployments SET status = 'error' "
            f"WHERE id = {sql_quote(deployment_id)}::uuid AND status = 'provisioning';"
        )
else:
    lines.append("-- no-op: reconciliation summary reports zero aged provisioning-lock rows")

for row in provisioning_age_distribution:
    age_bucket = row.get("age_bucket", "")
    bucket_count = to_int(row.get("count"))
    if age_bucket in {"1h_to_6h", "6h_to_24h", "gte_24h"} and bucket_count > 0:
        lines.append(
            "SELECT "
            f"{sql_quote(age_bucket)} AS age_bucket, "
            f"{bucket_count}::bigint AS provisioning_row_count, "
            "'aging_backlog_bucket' AS review_reason;"
        )
lines.append("")

lines.append("-- Evidence bucket: repeated shared-placement cohorts")
cohort_statement_emitted = False
for row in provisioning_by_customer_cohort:
    cohort_name = row.get("customer_cohort", "")
    provisioning_count = to_int(row.get("provisioning_count"))
    customer_count = to_int(row.get("customer_count"))
    if provisioning_count > customer_count and provisioning_count > 0:
        cohort_statement_emitted = True
        lines.append(
            "SELECT "
            f"{sql_quote(cohort_name)} AS customer_cohort, "
            f"{provisioning_count}::bigint AS provisioning_count, "
            f"{customer_count}::bigint AS customer_count, "
            "'multi_deployment_cohort' AS review_reason;"
        )
if not cohort_statement_emitted:
    lines.append("-- no-op: no cohort had provisioning_count > customer_count")
lines.append("")

lines.append("-- Evidence bucket: billing exposure counts")
if billing_accuracy_impact:
    impact = billing_accuracy_impact[0]
    missing_inventory_link_count = to_int(impact.get("provisioning_rows_missing_inventory_link"))
    provisioning_lock_count = to_int(impact.get("provisioning_lock_rows"))
    # Keep this bucket review-only: counts alone are not specific enough to
    # justify a row update without accidentally sweeping fresh lock markers that
    # Stage 1 still treats as in-flight rather than drift.
    lines.append(
        "SELECT "
        f"{missing_inventory_link_count}::bigint AS provisioning_rows_missing_inventory_link, "
        f"{provisioning_lock_count}::bigint AS provisioning_lock_rows, "
        "'billing_accuracy_impact' AS review_reason;"
    )
else:
    lines.append("-- no-op: billing_accuracy_impact.csv had no data rows")
lines.append("")

lines.append("-- Evidence bucket: detailed provisioning rows missing inventory link")
detailed_statement_emitted = False
for row in provisioning_rows_detailed:
    deployment_id = row.get("deployment_id")
    inventory_vm_id = (row.get("inventory_vm_id") or "").strip()
    if inventory_vm_id:
        continue
    detailed_statement_emitted = True
    lines.append(
        "SELECT "
        f"{sql_quote(deployment_id)} AS deployment_id, "
        "'provisioning_row_missing_inventory_link' AS review_reason;"
    )
if not detailed_statement_emitted:
    lines.append("-- no-op: detailed provisioning rows all had inventory links")
lines.append("")

lines.append("-- Evidence bucket: status-count context snapshots")
for row in vm_inventory_status_counts:
    lines.append(
        "SELECT "
        f"{sql_quote(row.get('status'))} AS vm_inventory_status, "
        f"{to_int(row.get('count'))}::bigint AS status_count;"
    )
for row in customer_deployments_status_counts:
    lines.append(
        "SELECT "
        f"{sql_quote(row.get('status'))} AS deployment_status, "
        f"{to_int(row.get('count'))}::bigint AS status_count;"
    )
lines.append("")

lines.append("ROLLBACK;")

print("\n".join(lines))
PY
then
    system_error "failed to render SQL proposals from evidence bundle"
fi
