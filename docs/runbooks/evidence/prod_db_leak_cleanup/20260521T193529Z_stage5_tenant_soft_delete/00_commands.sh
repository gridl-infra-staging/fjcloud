#!/usr/bin/env bash
# Stage 5 exact-cohort tenant soft-delete runner.
#
# Mutation owner:
#   DELETE /admin/tenants/{id}
#     -> infra/api/src/routes/admin/tenants.rs::delete_tenant
#     -> CustomerRepo::soft_delete
#
# Input SSOT:
#   - Stage 1 exact CSVs (cohort membership owner)
#   - Stage 4 40_stage4_summary.json (delete-eligibility/disposition owner)
#
# Contract:
#   - Fail closed if Stage 1 and Stage 4 customer sets disagree for any env.
#   - DELETE only rows whose Stage 4 customer_disposition == no_deployments.
#   - Staging list_http_404 rows are verification-only until read-only DB proof
#     confirms status='deleted' and deleted_at is non-null.
#
# Test mode:
#   STAGE5_TEST_MODE=1 bypasses .env/SSM resolution and uses STAGE5_* overrides.

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
STAGE4_SUMMARY_DEFAULT="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T191408Z_stage4_deployment_termination/40_stage4_summary.json"

STAGE1_DIR="${STAGE5_STAGE1_DIR:-$STAGE1_DIR_DEFAULT}"
STAGE4_SUMMARY_JSON="${STAGE5_STAGE4_SUMMARY_JSON:-$STAGE4_SUMMARY_DEFAULT}"
PROD_CSV="$STAGE1_DIR/10_prod_exact_cleanup.csv"
STAGING_CSV="$STAGE1_DIR/11_staging_exact_cleanup.csv"
STAGE1_SUMMARY_JSON="$STAGE1_DIR/40_stage1_summary.json"

if [ ! -f "$PROD_CSV" ] || [ ! -f "$STAGING_CSV" ] || [ ! -f "$STAGE4_SUMMARY_JSON" ]; then
    echo "ERROR: required Stage 1/Stage 4 input artifacts are missing." >&2
    echo "  PROD_CSV=$PROD_CSV" >&2
    echo "  STAGING_CSV=$STAGING_CSV" >&2
    echo "  STAGE4_SUMMARY_JSON=$STAGE4_SUMMARY_JSON" >&2
    exit 1
fi

OUT_DIR="${STAGE5_OUT_DIR:-$SCRIPT_DIR}"
RUN_DIR="$OUT_DIR/runs/$RUN_LABEL"
PLAN_DIR="$RUN_DIR/12_plan"
DELETE_DIR="$RUN_DIR/24_delete_attempts"
STAGING_VERIFY_DIR="$RUN_DIR/26_staging_404_verification"
mkdir -p "$PLAN_DIR" "$DELETE_DIR" "$STAGING_VERIFY_DIR"

LINEAGE_FILE="$RUN_DIR/00_lineage.json"
python3 - "$LINEAGE_FILE" "$PROD_CSV" "$STAGING_CSV" "$STAGE1_SUMMARY_JSON" "$STAGE4_SUMMARY_JSON" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
prod_csv = pathlib.Path(sys.argv[2])
staging_csv = pathlib.Path(sys.argv[3])
stage1_summary = pathlib.Path(sys.argv[4])
stage4_summary = pathlib.Path(sys.argv[5])

out.write_text(
    json.dumps(
        {
            "stage1_prod_exact_cleanup_csv": str(prod_csv),
            "stage1_staging_exact_cleanup_csv": str(staging_csv),
            "stage1_summary_json": str(stage1_summary),
            "stage4_summary_json": str(stage4_summary),
            "stage1_prod_exact_cleanup_csv_exists": prod_csv.exists(),
            "stage1_staging_exact_cleanup_csv_exists": staging_csv.exists(),
            "stage1_summary_json_exists": stage1_summary.exists(),
            "stage4_summary_json_exists": stage4_summary.exists(),
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

TEST_MODE="${STAGE5_TEST_MODE:-0}"
if [ "$TEST_MODE" = "1" ]; then
    PROD_API_URL="${STAGE5_API_URL_PROD:?STAGE5_API_URL_PROD required in test mode}"
    STAGING_API_URL="${STAGE5_API_URL_STAGING:?STAGE5_API_URL_STAGING required in test mode}"
    PROD_ADMIN_KEY="${STAGE5_ADMIN_KEY_PROD:?STAGE5_ADMIN_KEY_PROD required in test mode}"
    STAGING_ADMIN_KEY="${STAGE5_ADMIN_KEY_STAGING:?STAGE5_ADMIN_KEY_STAGING required in test mode}"
    STAGING_DATABASE_URL="${STAGE5_STAGING_DATABASE_URL:-postgres://stage5-test/staging}"
else
    SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/env.sh"
    load_layered_env_files "$SECRET_FILE"

    # Force AWS credential variables from the secrets file so stale exported
    # shell variables cannot shadow the repo-authorized credentials.
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        parse_env_assignment_line "$env_line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -ne 0 ]; then
            continue
        fi
        case "$ENV_ASSIGNMENT_KEY" in
            AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_DEFAULT_REGION)
                printf -v "$ENV_ASSIGNMENT_KEY" '%s' "$ENV_ASSIGNMENT_VALUE"
                export "$ENV_ASSIGNMENT_KEY"
                ;;
        esac
    done < "$SECRET_FILE"

    if [ -z "${PROD_API_URL:-${STAGE5_API_URL_PROD:-}}" ]; then
        PROD_API_URL="${API_URL:-https://api.flapjack.foo}"
    fi
    PROD_API_URL="${STAGE5_API_URL_PROD:-$PROD_API_URL}"
    PROD_ADMIN_KEY="${STAGE5_ADMIN_KEY_PROD:-${ADMIN_KEY:-}}"

    STAGING_API_URL="${STAGE5_API_URL_STAGING:-https://api.staging.flapjack.foo}"
    if [ -z "${STAGE5_ADMIN_KEY_STAGING:-}" ]; then
        STAGING_ADMIN_KEY="$(
            aws ssm get-parameter \
                --name "/fjcloud/staging/admin_key" \
                --with-decryption \
                --region "${AWS_DEFAULT_REGION:-us-east-1}" \
                --query 'Parameter.Value' --output text || true
        )"
    else
        STAGING_ADMIN_KEY="$STAGE5_ADMIN_KEY_STAGING"
    fi

    if [ -z "${STAGE5_STAGING_DATABASE_URL:-}" ]; then
        STAGING_DATABASE_URL="$(
            aws ssm get-parameter \
                --name "/fjcloud/staging/database_url" \
                --with-decryption \
                --region "${AWS_DEFAULT_REGION:-us-east-1}" \
                --query 'Parameter.Value' --output text || true
        )"
    else
        STAGING_DATABASE_URL="$STAGE5_STAGING_DATABASE_URL"
    fi

    if [ -z "$PROD_ADMIN_KEY" ] || [ "$PROD_ADMIN_KEY" = "None" ]; then
        echo "ERROR: prod ADMIN_KEY not resolved" >&2
        exit 1
    fi
    if [ -z "$STAGING_ADMIN_KEY" ] || [ "$STAGING_ADMIN_KEY" = "None" ]; then
        echo "ERROR: staging ADMIN_KEY not resolved" >&2
        exit 1
    fi
    if [ -z "$STAGING_DATABASE_URL" ] || [ "$STAGING_DATABASE_URL" = "None" ]; then
        echo "ERROR: staging database URL not resolved" >&2
        exit 1
    fi
fi

STAGING_DB_HELPER="${STAGE5_STAGING_DB_HELPER:-$REPO_ROOT/scripts/lib/staging_db.sh}"
# shellcheck source=/dev/null
source "$STAGING_DB_HELPER"

PLAN_JSON="$PLAN_DIR/12_execution_plan.json"
PLAN_TSV="$PLAN_DIR/12_execution_plan.tsv"

python3 - "$PROD_CSV" "$STAGING_CSV" "$STAGE4_SUMMARY_JSON" "$PLAN_JSON" "$PLAN_TSV" <<'PY'
import csv
import json
import pathlib
import re
import sys

prod_csv = pathlib.Path(sys.argv[1])
staging_csv = pathlib.Path(sys.argv[2])
stage4_summary_path = pathlib.Path(sys.argv[3])
plan_json_path = pathlib.Path(sys.argv[4])
plan_tsv_path = pathlib.Path(sys.argv[5])

uuid_re = re.compile(r"^[0-9a-fA-F-]{36}$")


def read_ids(csv_path):
    ids = []
    with csv_path.open("r", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            cid = (row.get("customer_id") or "").strip()
            if cid:
                ids.append(cid)
    return ids

prod_ids = read_ids(prod_csv)
staging_ids = read_ids(staging_csv)
stage1_ids = {"prod": prod_ids, "staging": staging_ids}

stage4 = json.loads(stage4_summary_path.read_text(encoding="utf-8"))
customer_dispositions = stage4.get("customer_dispositions") or {}
stage4_ids = {
    "prod": list((customer_dispositions.get("prod") or {}).keys()),
    "staging": list((customer_dispositions.get("staging") or {}).keys()),
}

violations = []
plan_rows = []

for env_name in ("prod", "staging"):
    stage1_set = set(stage1_ids[env_name])
    stage4_set = set(stage4_ids[env_name])
    missing = sorted(stage1_set - stage4_set)
    extra = sorted(stage4_set - stage1_set)
    for cid in missing:
        violations.append(f"stage4_missing_customer:{env_name}:{cid}")
    for cid in extra:
        violations.append(f"stage4_extra_customer:{env_name}:{cid}")

if violations:
    sys.stderr.write("Stage 5 input disagreement between Stage 1 and Stage 4:\n")
    for v in violations:
        sys.stderr.write(f"  {v}\n")
    raise SystemExit(1)

for env_name in ("prod", "staging"):
    env_rows = customer_dispositions.get(env_name) or {}
    for customer_id in stage1_ids[env_name]:
        if not uuid_re.match(customer_id):
            violations.append(f"invalid_customer_id_format:{env_name}:{customer_id}")
            continue

        detail = env_rows.get(customer_id) or {}
        disposition = detail.get("customer_disposition") or "unknown"
        deployment_rows = detail.get("deployment_rows") or []
        execution_reasons = [
            row.get("execution_reason")
            for row in deployment_rows
            if isinstance(row, dict) and row.get("execution_reason")
        ]
        list_http_codes = [
            str(row.get("list_http_code"))
            for row in deployment_rows
            if isinstance(row, dict) and row.get("list_http_code") is not None
        ]

        stage4_reason = execution_reasons[0] if execution_reasons else "none"

        if disposition == "no_deployments":
            action = "delete"
        elif (
            env_name == "staging"
            and disposition == "list_failed"
            and (
                "list_http_404" in execution_reasons
                or "404" in list_http_codes
            )
        ):
            action = "verify_404"
        else:
            violations.append(
                f"unexpected_stage4_disposition:{env_name}:{customer_id}:{disposition}"
            )
            action = "invalid"

        plan_rows.append(
            {
                "environment": env_name,
                "customer_id": customer_id,
                "stage4_customer_disposition": disposition,
                "stage4_reason": stage4_reason,
                "action": action,
            }
        )

if violations:
    sys.stderr.write("Stage 5 execution-plan contract violations:\n")
    for v in violations:
        sys.stderr.write(f"  {v}\n")
    raise SystemExit(1)

plan_json_path.write_text(json.dumps(plan_rows, indent=2) + "\n", encoding="utf-8")
with plan_tsv_path.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.writer(fh, delimiter="\t", lineterminator="\n")
    writer.writerow(
        [
            "environment",
            "customer_id",
            "stage4_customer_disposition",
            "stage4_reason",
            "action",
        ]
    )
    for row in plan_rows:
        writer.writerow(
            [
                row["environment"],
                row["customer_id"],
                row["stage4_customer_disposition"],
                row["stage4_reason"],
                row["action"],
            ]
        )
PY

PRIMARY_TERMINAL_KEYS_FILE="$RUN_DIR/18_primary_terminal_keys.tsv"
if [ "$RUN_LABEL" = "rerun" ]; then
    PRIMARY_DISP_JSON="$OUT_DIR/runs/primary/30_stage5_soft_delete_dispositions.json"
    if [ -f "$PRIMARY_DISP_JSON" ]; then
        python3 - "$PRIMARY_DISP_JSON" "$PRIMARY_TERMINAL_KEYS_FILE" <<'PY'
import json
import pathlib
import sys

rows = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out = pathlib.Path(sys.argv[2])
term = {
    (row["environment"], row["customer_id"])
    for row in rows
    if row.get("bucket") in {"soft_deleted_via_admin_route", "already_deleted_confirmed"}
}
out.write_text(
    "\n".join(f"{env}\t{cid}" for env, cid in sorted(term)) + "\n",
    encoding="utf-8",
)
PY
    else
        : > "$PRIMARY_TERMINAL_KEYS_FILE"
    fi
else
    : > "$PRIMARY_TERMINAL_KEYS_FILE"
fi

REQUEST_DELAY_SECONDS="${STAGE5_REQUEST_DELAY_SECONDS:-0.5}"
MAX_429_RETRIES="${STAGE5_MAX_429_RETRIES:-4}"

is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]
}

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
        sleep $((8 + attempt * 10))
    done
    ADMIN_REQ_CODE="$code"
}

# Verify an already-deleted tenant through the canonical admin read route.
# Returns success only when GET /admin/tenants/{id} returns 2xx JSON with
# status == "deleted".
verify_deleted_via_admin_get() {
    local out_body="$1" api_url="$2" admin_key="$3" customer_id="$4"
    admin_request "$out_body" "GET" "${api_url}/admin/tenants/${customer_id}" "$admin_key"
    local get_code="$ADMIN_REQ_CODE"
    if [[ ! "$get_code" =~ ^2 ]]; then
        return 1
    fi
    python3 - "$out_body" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("status") != "deleted":
    raise SystemExit(1)
PY
}

# Read-only staging DB proof for customers that must already be soft-deleted.
verify_staging_deleted_customer() {
    local customer_id="$1" raw_out="$2" parsed_out="$3"
    if ! is_uuid "$customer_id"; then
        echo "ERROR: invalid customer_id format for staging DB verification: $customer_id" >&2
        return 2
    fi
    local sql
    sql="COPY (SELECT status, deleted_at FROM customers WHERE id = '${customer_id}') TO STDOUT WITH CSV HEADER"

    # staging_db_run_sql resolves target host by DATABASE_URL_SSM_PARAM unless
    # SSM_INSTANCE_ID is explicitly set.
    if ! DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url" \
        staging_db_run_sql "$STAGING_DATABASE_URL" "$sql" > "$raw_out"; then
        python3 - "$parsed_out" "$customer_id" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "customer_id": sys.argv[2],
            "db_proof_status": "query_failed",
            "status": None,
            "deleted_at": None,
            "confirmed_deleted": False,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
        return 2
    fi

    python3 - "$raw_out" "$parsed_out" "$customer_id" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
customer_id = sys.argv[3]
text = raw_path.read_text(encoding="utf-8", errors="replace")

status = None
deleted_at = None
for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith("COPY"):
        continue
    if line.lower().startswith("status,"):
        continue
    if "," in line:
        left, right = line.split(",", 1)
        status = left.strip().strip('"')
        deleted_at = right.strip().strip('"')
        break

confirmed = (status == "deleted" and bool(deleted_at))
proof_status = "confirmed" if confirmed else "not_deleted"
payload = {
    "customer_id": customer_id,
    "db_proof_status": proof_status,
    "status": status,
    "deleted_at": deleted_at,
    "confirmed_deleted": confirmed,
}
out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
if not confirmed:
    raise SystemExit(1)
PY
}

RESULTS_TSV="$RUN_DIR/29_stage5_results.tsv"
: > "$RESULTS_TSV"

while IFS=$'\t' read -r environment customer_id stage4_disposition stage4_reason action; do
    if [ "$environment" = "environment" ]; then
        continue
    fi
    action="${action%$'\r'}"
    if ! is_uuid "$customer_id"; then
        echo "ERROR: invalid customer_id format in Stage 5 plan: $customer_id" >&2
        exit 1
    fi

    safe_id="${customer_id//[^a-zA-Z0-9_-]/_}"
    request_meta_file=""
    response_body_file=""
    db_raw_file=""
    db_parsed_file=""
    delete_http_code=""
    bucket="delete_failed"
    bucket_reason="unclassified"

    case "$action" in
        delete)
            response_body_file="$DELETE_DIR/${environment}_${safe_id}_delete.body"
            request_meta_file="$DELETE_DIR/${environment}_${safe_id}_delete.meta.json"
            if [ "$environment" = "prod" ]; then
                api_url="$PROD_API_URL"
                admin_key="$PROD_ADMIN_KEY"
            else
                api_url="$STAGING_API_URL"
                admin_key="$STAGING_ADMIN_KEY"
            fi

            admin_request "$response_body_file" "DELETE" "${api_url}/admin/tenants/${customer_id}" "$admin_key"
            delete_http_code="$ADMIN_REQ_CODE"
            if [ "$REQUEST_DELAY_SECONDS" != "0" ]; then
                sleep "$REQUEST_DELAY_SECONDS"
            fi

            python3 - "$request_meta_file" "$environment" "$customer_id" "$delete_http_code" "${api_url}/admin/tenants/${customer_id}" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        {
            "environment": sys.argv[2],
            "customer_id": sys.argv[3],
            "request": {
                "method": "DELETE",
                "url": sys.argv[5],
            },
            "delete_http_code": sys.argv[4],
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

            if [[ "$delete_http_code" =~ ^2 ]]; then
                bucket="soft_deleted_via_admin_route"
                bucket_reason="delete_http_${delete_http_code}"
            elif [ "$delete_http_code" = "404" ]; then
                get_verify_body="$DELETE_DIR/${environment}_${safe_id}_delete_404_get.json"
                if verify_deleted_via_admin_get "$get_verify_body" "$api_url" "$admin_key" "$customer_id"; then
                    bucket="already_deleted_confirmed"
                    bucket_reason="delete_404_admin_get_deleted"
                elif grep -Fqx "$environment	$customer_id" "$PRIMARY_TERMINAL_KEYS_FILE" 2>/dev/null; then
                    bucket="already_deleted_confirmed"
                    bucket_reason="rerun_404_after_primary_terminal"
                elif [ "$environment" = "staging" ]; then
                    db_raw_file="$STAGING_VERIFY_DIR/${environment}_${safe_id}_delete_404_db.raw.txt"
                    db_parsed_file="$STAGING_VERIFY_DIR/${environment}_${safe_id}_delete_404_db.json"
                    if verify_staging_deleted_customer "$customer_id" "$db_raw_file" "$db_parsed_file"; then
                        bucket="already_deleted_confirmed"
                        bucket_reason="delete_404_db_confirmed"
                    else
                        bucket="delete_failed"
                        bucket_reason="delete_404_not_confirmed"
                    fi
                else
                    bucket="delete_failed"
                    bucket_reason="delete_404_without_primary_terminal"
                fi
            else
                bucket="delete_failed"
                bucket_reason="delete_http_${delete_http_code:-unknown}"
            fi
            ;;

        verify_404)
            db_raw_file="$STAGING_VERIFY_DIR/${environment}_${safe_id}_list_404_db.raw.txt"
            db_parsed_file="$STAGING_VERIFY_DIR/${environment}_${safe_id}_list_404_db.json"
            if verify_staging_deleted_customer "$customer_id" "$db_raw_file" "$db_parsed_file"; then
                bucket="already_deleted_confirmed"
                bucket_reason="stage4_list_http_404_db_confirmed"
            else
                bucket="delete_failed"
                bucket_reason="stage4_list_http_404_not_deleted"
            fi
            ;;

        *)
            bucket="delete_failed"
            bucket_reason="invalid_action:${action}"
            ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$environment" "$customer_id" "$stage4_disposition" "$stage4_reason" "$action" \
        "$delete_http_code" "$bucket" "$bucket_reason" "$request_meta_file" "$response_body_file" "$db_parsed_file" \
        >> "$RESULTS_TSV"
done < "$PLAN_TSV"

DISP_JSON="$RUN_DIR/30_stage5_soft_delete_dispositions.json"
DISP_CSV="$RUN_DIR/31_stage5_soft_delete_dispositions.csv"
SUMMARY_JSON="$RUN_DIR/40_stage5_soft_delete_summary.json"

python3 - "$RESULTS_TSV" "$PROD_CSV" "$STAGING_CSV" "$DISP_JSON" "$DISP_CSV" "$SUMMARY_JSON" "$RUN_LABEL" <<'PY'
import csv
import json
import pathlib
import sys

results_tsv = pathlib.Path(sys.argv[1])
prod_csv = pathlib.Path(sys.argv[2])
staging_csv = pathlib.Path(sys.argv[3])
disp_json_path = pathlib.Path(sys.argv[4])
disp_csv_path = pathlib.Path(sys.argv[5])
summary_path = pathlib.Path(sys.argv[6])
run_label = sys.argv[7]


def read_ids(csv_path):
    ids = []
    with csv_path.open("r", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            cid = (row.get("customer_id") or "").strip()
            if cid:
                ids.append(cid)
    return ids

prod_ids = read_ids(prod_csv)
staging_ids = read_ids(staging_csv)
allowed = {("prod", cid) for cid in prod_ids} | {("staging", cid) for cid in staging_ids}

rows = []
seen = set()
violations = []

with results_tsv.open("r", encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\r\n")
        if not line:
            continue
        fields = line.split("\t")
        while len(fields) < 11:
            fields.append("")
        (
            environment,
            customer_id,
            stage4_disposition,
            stage4_reason,
            action,
            delete_http_code,
            bucket,
            bucket_reason,
            request_meta_file,
            response_body_file,
            db_proof_file,
        ) = fields[:11]

        key = (environment, customer_id)
        seen.add(key)
        if key not in allowed:
            violations.append(f"out_of_scope_customer:{environment}:{customer_id}")

        row = {
            "environment": environment,
            "customer_id": customer_id,
            "stage4_customer_disposition": stage4_disposition,
            "stage4_reason": stage4_reason,
            "action": action,
            "delete_http_code": delete_http_code or None,
            "bucket": bucket,
            "bucket_reason": bucket_reason,
            "request_meta_file": request_meta_file or None,
            "response_body_file": response_body_file or None,
            "db_proof_file": db_proof_file or None,
        }
        rows.append(row)
        if bucket == "delete_failed":
            violations.append(f"delete_failed:{environment}:{customer_id}:{bucket_reason}")

for env_name, cid in sorted(allowed - seen):
    violations.append(f"missing_result_row:{env_name}:{cid}")

bucket_names = [
    "soft_deleted_via_admin_route",
    "already_deleted_confirmed",
    "delete_failed",
]


def counts_for(env_name):
    env_rows = [r for r in rows if r["environment"] == env_name]
    return {
        bucket: sum(1 for r in env_rows if r["bucket"] == bucket)
        for bucket in bucket_names
    }

prod_counts = counts_for("prod")
staging_counts = counts_for("staging")
total_counts = {
    bucket: prod_counts[bucket] + staging_counts[bucket]
    for bucket in bucket_names
}

summary = {
    "run_label": run_label,
    "lineage": {
        "stage1_prod_exact_cleanup_csv": str(prod_csv),
        "stage1_staging_exact_cleanup_csv": str(staging_csv),
    },
    "active_exact_cleanup_customers": {
        "source": "Stage 1 exact CSVs",
        "prod": len(prod_ids),
        "staging": len(staging_ids),
        "total": len(prod_ids) + len(staging_ids),
    },
    "bucket_counts": total_counts,
    "per_environment": {
        "prod": {
            "csv_customer_count": len(prod_ids),
            **prod_counts,
        },
        "staging": {
            "csv_customer_count": len(staging_ids),
            **staging_counts,
        },
    },
    "post_delete_status_evidence_pointers": {
        "disposition_table_json": str(disp_json_path),
        "disposition_table_csv": str(disp_csv_path),
    },
    "violations": violations,
}

disp_json_path.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
with disp_csv_path.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.writer(fh)
    writer.writerow(
        [
            "environment",
            "customer_id",
            "stage4_customer_disposition",
            "stage4_reason",
            "action",
            "delete_http_code",
            "bucket",
            "bucket_reason",
            "request_meta_file",
            "response_body_file",
            "db_proof_file",
        ]
    )
    for row in rows:
        writer.writerow(
            [
                row["environment"],
                row["customer_id"],
                row["stage4_customer_disposition"],
                row["stage4_reason"],
                row["action"],
                row["delete_http_code"] or "",
                row["bucket"],
                row["bucket_reason"],
                row["request_meta_file"] or "",
                row["response_body_file"] or "",
                row["db_proof_file"] or "",
            ]
        )

summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

if violations:
    sys.stderr.write("Stage 5 contract violations:\n")
    for violation in violations:
        sys.stderr.write(f"  {violation}\n")
    raise SystemExit(1)
PY

echo "Stage 5 run complete: $RUN_DIR" >&2
