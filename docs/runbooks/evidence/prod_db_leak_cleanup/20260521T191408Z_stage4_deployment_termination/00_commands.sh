#!/usr/bin/env bash
# Stage 4 admin-route deployment termination runner.
#
# Purpose
#   Terminate exact-cohort deployments through the canonical admin route
#       /admin/tenants/{customer_id}/deployments       (list, pre-mutation)
#       /admin/deployments/{deployment_id}             (DELETE, mutation)
#   for every customer in the Stage 1 exact CSV pair:
#       docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory/10_prod_exact_cleanup.csv
#       docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory/11_staging_exact_cleanup.csv
#
# Source of truth
#   The Stage 1 exact CSVs are the ONLY input set this runner ever queries.
#   No customer ID is touched unless it appears in those CSVs. The runner
#   never reads tenants from the DB, never enumerates anything broader, and
#   never falls back to a hardcoded list.
#
# Single mutation seam
#   Mutations flow through `terminate_deployment` at
#       infra/api/src/routes/admin/deployments.rs:214-220
#   which calls `PgDeploymentRepo::terminate` at
#       infra/api/src/repos/pg_deployment_repo.rs:113-121
#   This stage proves DB termination through that path. Provider-side
#   VM/DNS/SSM teardown lives in `ProvisioningService::terminate_deployment`
#   and is NOT exercised here.
#
# Test mode
#   When STAGE4_TEST_MODE=1, every credential/URL is taken from STAGE4_*
#   overrides and SSM/.env loading is skipped. This is how
#   scripts/tests/stage4_deployment_termination_contract_test.sh drives
#   the runner against a mock admin server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

RUN_LABEL="${1:-primary}"
case "$RUN_LABEL" in
    primary|rerun) ;;
    *)
        echo "Usage: $0 [primary|rerun]" >&2
        exit 2
        ;;
esac

STAGE1_DIR_DEFAULT="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory"
STAGE1_DIR="${STAGE4_STAGE1_DIR:-$STAGE1_DIR_DEFAULT}"
PROD_CSV="$STAGE1_DIR/10_prod_exact_cleanup.csv"
STAGING_CSV="$STAGE1_DIR/11_staging_exact_cleanup.csv"
STAGE1_SUMMARY_JSON="$STAGE1_DIR/40_stage1_summary.json"

if [ ! -f "$PROD_CSV" ] || [ ! -f "$STAGING_CSV" ]; then
    echo "ERROR: missing Stage 1 exact-cohort CSVs:" >&2
    echo "  $PROD_CSV" >&2
    echo "  $STAGING_CSV" >&2
    exit 1
fi

OUT_DIR="${STAGE4_OUT_DIR:-$SCRIPT_DIR}"
RUN_DIR="$OUT_DIR/runs/$RUN_LABEL"
PRE_DELETE_DIR="$RUN_DIR/20_pre_delete_deployments"
DELETE_DIR="$RUN_DIR/24_delete_attempts"
mkdir -p "$PRE_DELETE_DIR" "$DELETE_DIR"

# ---------------------------------------------------------------------------
# Lineage manifest — pins Stage 1 + Stage 3 source paths inside the run.
# ---------------------------------------------------------------------------
LINEAGE_FILE="$RUN_DIR/00_lineage.json"
STAGE3_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T182407Z_stage3_refund_execution"
python3 - "$LINEAGE_FILE" "$PROD_CSV" "$STAGING_CSV" "$STAGE1_SUMMARY_JSON" \
    "$STAGE3_DIR/40_refund_execution_summary.json" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
prod_csv = pathlib.Path(sys.argv[2])
staging_csv = pathlib.Path(sys.argv[3])
stage1_summary = pathlib.Path(sys.argv[4])
stage3_summary = pathlib.Path(sys.argv[5])

manifest = {
    "stage1_prod_exact_cleanup_csv": str(prod_csv),
    "stage1_staging_exact_cleanup_csv": str(staging_csv),
    "stage1_summary_json": str(stage1_summary),
    "stage3_refund_execution_summary_json": str(stage3_summary),
    "stage1_prod_exact_cleanup_csv_exists": prod_csv.exists(),
    "stage1_staging_exact_cleanup_csv_exists": staging_csv.exists(),
    "stage1_summary_json_exists": stage1_summary.exists(),
    "stage3_refund_execution_summary_json_exists": stage3_summary.exists(),
}
out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

# ---------------------------------------------------------------------------
# Credential + URL resolution.
#
# Test mode: pull straight from STAGE4_* overrides.
# Live mode: load .env.secret + SSM via the existing hydrate helper.
# ---------------------------------------------------------------------------
TEST_MODE="${STAGE4_TEST_MODE:-0}"
if [ "$TEST_MODE" = "1" ]; then
    PROD_API_URL="${STAGE4_API_URL_PROD:?STAGE4_API_URL_PROD required in test mode}"
    STAGING_API_URL="${STAGE4_API_URL_STAGING:?STAGE4_API_URL_STAGING required in test mode}"
    PROD_ADMIN_KEY="${STAGE4_ADMIN_KEY_PROD:?STAGE4_ADMIN_KEY_PROD required in test mode}"
    STAGING_ADMIN_KEY="${STAGE4_ADMIN_KEY_STAGING:?STAGE4_ADMIN_KEY_STAGING required in test mode}"
else
    SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/env.sh"
    load_layered_env_files "$SECRET_FILE"

    if [ -z "${PROD_API_URL:-${STAGE4_API_URL_PROD:-}}" ]; then
        PROD_API_URL="${API_URL:-https://api.flapjack.foo}"
    fi
    PROD_API_URL="${STAGE4_API_URL_PROD:-$PROD_API_URL}"
    PROD_ADMIN_KEY="${STAGE4_ADMIN_KEY_PROD:-${ADMIN_KEY:-}}"

    STAGING_API_URL="${STAGE4_API_URL_STAGING:-https://api.staging.flapjack.foo}"
    if [ -z "${STAGE4_ADMIN_KEY_STAGING:-}" ]; then
        STAGING_ADMIN_KEY="$(
            aws ssm get-parameter \
                --name "/fjcloud/staging/admin_key" \
                --with-decryption \
                --region "${AWS_DEFAULT_REGION:-us-east-1}" \
                --query 'Parameter.Value' --output text 2>/dev/null \
        )"
    else
        STAGING_ADMIN_KEY="$STAGE4_ADMIN_KEY_STAGING"
    fi

    if [ -z "$PROD_ADMIN_KEY" ] || [ "$PROD_ADMIN_KEY" = "None" ]; then
        echo "ERROR: prod ADMIN_KEY not resolved from .env.secret" >&2
        exit 1
    fi
    if [ -z "$STAGING_ADMIN_KEY" ] || [ "$STAGING_ADMIN_KEY" = "None" ]; then
        echo "ERROR: staging ADMIN_KEY not resolved from SSM" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Per-environment processing.
#
# For every CSV customer_id:
#   1. GET /admin/tenants/{id}/deployments?include_terminated=true
#      (captured to $PRE_DELETE_DIR/<env>_<customer>.json)
#   2. For each non-terminated deployment in the response, DELETE it via
#      /admin/deployments/{deployment_id} and record HTTP code + body.
#   3. For pre-terminated deployments, emit a no-op disposition row.
# ---------------------------------------------------------------------------
ATTEMPTS_TSV="$RUN_DIR/24_delete_attempts.tsv"
: > "$ATTEMPTS_TSV"

# Live deployment admin endpoints sit behind a 30 RPM per-IP limiter
# (infra/api/src/router.rs::DEFAULT_ADMIN_RATE_LIMIT_RPM = 30 in a 60s window).
# A 2.5s inter-request delay keeps us under the limiter (24 RPM) and a
# capped 429-retry-with-backoff handles bursts when other consumers share
# the IP. STAGE4_REQUEST_DELAY_SECONDS=0 in test mode skips the sleep so
# the contract test runs quickly.
DEFAULT_DELAY_SECONDS="2.5"
if [ "$TEST_MODE" = "1" ]; then
    DEFAULT_DELAY_SECONDS="0"
fi
REQUEST_DELAY_SECONDS="${STAGE4_REQUEST_DELAY_SECONDS:-$DEFAULT_DELAY_SECONDS}"
MAX_429_RETRIES="${STAGE4_MAX_429_RETRIES:-4}"

is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]
}

# Args: out_body_path method url admin_key
# Sets ADMIN_REQ_CODE on return. Retries up to MAX_429_RETRIES on HTTP 429
# using the limiter's window-based retry hint, otherwise fixed backoff.
admin_request() {
    local out_body="$1" method="$2" url="$3" admin_key="$4"
    local attempt code
    for ((attempt = 0; attempt <= MAX_429_RETRIES; attempt++)); do
        code="$(
            curl -sS -o "$out_body" -w "%{http_code}" \
                -X "$method" "$url" \
                -H "x-admin-key: ${admin_key}" \
                -H "Content-Type: application/json" || true
        )"
        code="${code:-000}"
        if [ "$code" != "429" ]; then
            ADMIN_REQ_CODE="$code"
            return 0
        fi
        # 429 hit — back off based on the 60s sliding window the API uses.
        local backoff=$((10 + attempt * 15))
        sleep "$backoff"
    done
    ADMIN_REQ_CODE="$code"
}

process_environment() {
    local env_name="$1" api_url="$2" admin_key="$3" csv_path="$4"
    local customer_id
    # Skip header line; column 1 is customer_id.
    while IFS=',' read -r customer_id _rest; do
        case "$customer_id" in
            ""|"customer_id") continue ;;
        esac
        # Strip CR if any.
        customer_id="${customer_id%$'\r'}"
        if ! is_uuid "$customer_id"; then
            echo "ERROR: invalid customer_id format in $csv_path: $customer_id" >&2
            exit 1
        fi

        local safe_id="${customer_id//[^a-zA-Z0-9_-]/_}"
        local list_body_path="$PRE_DELETE_DIR/${env_name}_${safe_id}_list.json"
        local list_meta_path="$PRE_DELETE_DIR/${env_name}_${safe_id}_list.meta.json"
        local http_code
        admin_request \
            "$list_body_path" \
            "GET" \
            "${api_url}/admin/tenants/${customer_id}/deployments?include_terminated=true" \
            "$admin_key"
        http_code="$ADMIN_REQ_CODE"
        if [ "$REQUEST_DELAY_SECONDS" != "0" ]; then
            sleep "$REQUEST_DELAY_SECONDS"
        fi
        python3 - "$list_meta_path" "$env_name" "$customer_id" "$http_code" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "environment": sys.argv[2],
            "customer_id": sys.argv[3],
            "list_http_code": sys.argv[4],
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

        # If list returned non-2xx, treat all deployments as unknown — do NOT
        # mutate. Record one TSV row with an empty deployment id and propagate
        # the HTTP code into the disposition assembler below.
        if [[ ! "$http_code" =~ ^2 ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$env_name" "$customer_id" "" "" "$http_code" "" \
                >> "$ATTEMPTS_TSV"
            continue
        fi

        # Parse the deployment array. Each row in the TSV is one deployment
        # the runner considered — including pre-terminated ones (recorded
        # with status=terminated and no DELETE attempt).
        local deployment_lines
        deployment_lines="$(
            python3 - "$list_body_path" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
try:
    data = json.loads(raw)
except Exception:
    data = []
if not isinstance(data, list):
    data = []
for dep in data:
    dep_id = dep.get("id") or ""
    status = dep.get("status") or ""
    print(f"{dep_id}\t{status}")
PY
        )"

        if [ -z "$deployment_lines" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$env_name" "$customer_id" "" "no_deployments" "$http_code" "" \
                >> "$ATTEMPTS_TSV"
            continue
        fi

        while IFS=$'\t' read -r dep_id dep_status; do
            [ -n "$dep_id" ] || continue
            local safe_dep="${dep_id//[^a-zA-Z0-9_-]/_}"
            local del_body_path="$DELETE_DIR/${env_name}_${safe_dep}_delete.body"
            local del_code=""

            if [ "$dep_status" = "terminated" ]; then
                # Recorded but not mutated.
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$env_name" "$customer_id" "$dep_id" "$dep_status" "$http_code" "" \
                    >> "$ATTEMPTS_TSV"
                continue
            fi

            admin_request \
                "$del_body_path" \
                "DELETE" \
                "${api_url}/admin/deployments/${dep_id}" \
                "$admin_key"
            del_code="$ADMIN_REQ_CODE"
            if [ "$REQUEST_DELAY_SECONDS" != "0" ]; then
                sleep "$REQUEST_DELAY_SECONDS"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$env_name" "$customer_id" "$dep_id" "$dep_status" "$http_code" "$del_code" \
                >> "$ATTEMPTS_TSV"
        done <<< "$deployment_lines"
    done < "$csv_path"
}

process_environment "prod"    "$PROD_API_URL"    "$PROD_ADMIN_KEY"    "$PROD_CSV"
process_environment "staging" "$STAGING_API_URL" "$STAGING_ADMIN_KEY" "$STAGING_CSV"

# ---------------------------------------------------------------------------
# Disposition assembly.
#
# Single source of truth: every Stage 4 summary value and every Stage 5
# handoff input is derived from this disposition table. Do NOT maintain a
# parallel customer/deployment list elsewhere.
# ---------------------------------------------------------------------------
DISP_JSON="$RUN_DIR/30_termination_dispositions.json"
DISP_CSV="$RUN_DIR/31_termination_dispositions.csv"
SUMMARY_JSON="$RUN_DIR/40_stage4_termination_summary.json"

python3 - "$ATTEMPTS_TSV" "$PROD_CSV" "$STAGING_CSV" "$DISP_JSON" "$DISP_CSV" "$SUMMARY_JSON" "$RUN_LABEL" <<'PY'
import csv
import json
import pathlib
import sys

attempts_path = pathlib.Path(sys.argv[1])
prod_csv = pathlib.Path(sys.argv[2])
staging_csv = pathlib.Path(sys.argv[3])
disp_json_path = pathlib.Path(sys.argv[4])
disp_csv_path = pathlib.Path(sys.argv[5])
summary_path = pathlib.Path(sys.argv[6])
run_label = sys.argv[7]


def read_customer_ids(csv_path):
    ids = []
    with csv_path.open("r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            cid = (row.get("customer_id") or "").strip()
            if cid:
                ids.append(cid)
    return ids


prod_ids = read_customer_ids(prod_csv)
staging_ids = read_customer_ids(staging_csv)
allowed_ids = {("prod", cid) for cid in prod_ids} | {("staging", cid) for cid in staging_ids}

dispositions = []
seen_customers = set()
violations = []

if attempts_path.exists():
    with attempts_path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            while len(fields) < 6:
                fields.append("")
            env_name, customer_id, dep_id, dep_status, list_http, del_http = fields[:6]
            seen_customers.add((env_name, customer_id))

            if (env_name, customer_id) not in allowed_ids:
                violations.append(
                    f"out_of_scope_customer:{env_name}:{customer_id}"
                )

            if not list_http.startswith("2"):
                execution_disposition = "list_failed"
                execution_reason = f"list_http_{list_http or 'unknown'}"
            elif dep_status == "no_deployments":
                execution_disposition = "no_deployments"
                execution_reason = "customer_has_zero_deployments"
            elif dep_status == "terminated":
                execution_disposition = "already_terminated_noop"
                execution_reason = "deployment_status_was_terminated_before_stage4"
            elif del_http == "204":
                execution_disposition = "terminated_via_admin_route"
                execution_reason = "delete_http_204"
            elif del_http == "404":
                # Concurrent / between-list-and-delete termination.
                execution_disposition = "already_terminated_concurrent"
                execution_reason = "delete_http_404_after_2xx_list"
            elif del_http.startswith("2"):
                execution_disposition = "terminated_other_2xx"
                execution_reason = f"delete_http_{del_http}"
            else:
                execution_disposition = "delete_failed"
                execution_reason = f"delete_http_{del_http or 'unknown'}"

            dispositions.append(
                {
                    "environment": env_name,
                    "customer_id": customer_id,
                    "deployment_id": dep_id or None,
                    "pre_delete_status": dep_status or None,
                    "list_http_code": list_http or None,
                    "delete_http_code": del_http or None,
                    "execution_disposition": execution_disposition,
                    "execution_reason": execution_reason,
                }
            )

# Every CSV customer must have been visited.
missing = sorted(allowed_ids - seen_customers)
for env_name, cid in missing:
    violations.append(f"unvisited_customer:{env_name}:{cid}")

disp_json_path.write_text(json.dumps(dispositions, indent=2) + "\n", encoding="utf-8")
with disp_csv_path.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.writer(fh)
    writer.writerow(
        [
            "environment",
            "customer_id",
            "deployment_id",
            "pre_delete_status",
            "list_http_code",
            "delete_http_code",
            "execution_disposition",
            "execution_reason",
        ]
    )
    for row in dispositions:
        writer.writerow(
            [
                row["environment"],
                row["customer_id"],
                row["deployment_id"] or "",
                row["pre_delete_status"] or "",
                row["list_http_code"] or "",
                row["delete_http_code"] or "",
                row["execution_disposition"],
                row["execution_reason"],
            ]
        )

# Summary counts.
def count(env_name, disposition):
    return sum(
        1 for r in dispositions
        if r["environment"] == env_name and r["execution_disposition"] == disposition
    )

def customers_with_disposition(env_name, dispositions_set):
    return sorted(
        {
            r["customer_id"]
            for r in dispositions
            if r["environment"] == env_name and r["execution_disposition"] in dispositions_set
        }
    )

terminating_set = {"terminated_via_admin_route", "terminated_other_2xx"}
already_set = {"already_terminated_noop", "already_terminated_concurrent"}
empty_set = {"no_deployments"}

summary = {
    "run_label": run_label,
    "violations": violations,
    "prod": {
        "csv_customer_count": len(prod_ids),
        "deployments_terminated": count("prod", "terminated_via_admin_route") + count("prod", "terminated_other_2xx"),
        "deployments_already_terminated_noop": count("prod", "already_terminated_noop"),
        "deployments_already_terminated_concurrent": count("prod", "already_terminated_concurrent"),
        "customers_no_deployments": count("prod", "no_deployments"),
        "list_failed_rows": count("prod", "list_failed"),
        "delete_failed_rows": count("prod", "delete_failed"),
        "customers_with_terminations": customers_with_disposition("prod", terminating_set),
        "customers_already_terminated": customers_with_disposition("prod", already_set),
        "customers_no_deployments_ids": customers_with_disposition("prod", empty_set),
    },
    "staging": {
        "csv_customer_count": len(staging_ids),
        "deployments_terminated": count("staging", "terminated_via_admin_route") + count("staging", "terminated_other_2xx"),
        "deployments_already_terminated_noop": count("staging", "already_terminated_noop"),
        "deployments_already_terminated_concurrent": count("staging", "already_terminated_concurrent"),
        "customers_no_deployments": count("staging", "no_deployments"),
        "list_failed_rows": count("staging", "list_failed"),
        "delete_failed_rows": count("staging", "delete_failed"),
        "customers_with_terminations": customers_with_disposition("staging", terminating_set),
        "customers_already_terminated": customers_with_disposition("staging", already_set),
        "customers_no_deployments_ids": customers_with_disposition("staging", empty_set),
    },
}

summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

if violations:
    sys.stderr.write("Stage 4 contract violations:\n")
    for v in violations:
        sys.stderr.write(f"  {v}\n")
    raise SystemExit(1)
PY

echo "Stage 4 run complete: $RUN_DIR" >&2
