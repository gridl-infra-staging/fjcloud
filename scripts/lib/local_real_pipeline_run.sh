#!/usr/bin/env bash
# Full-mode orchestration for scripts/local_real_pipeline_probe.sh.
#
# Sourced ONLY on the probe's zero-argument (full) path, so the classifier
# (`--assert-evidence`) surface stays a pure, dependency-free known-answer
# classifier with no live side effects. The probe remains the single owner and
# entry point; this file is its full-mode implementation module.
#
# It reuses the existing local-stack scripts (local_demo.sh, local-dev-up.sh,
# api-dev.sh, seed_local.sh, start-metering.sh, run-aggregation-job.sh,
# local-dev-down.sh) and the shared library owners instead of re-implementing
# any of them, and drives the load-bearing two-scrape bracket:
#   bring up stack -> baseline scrape -> read /metrics PRE -> drive KNOWN
#   traffic -> next scrape -> read /metrics POST -> aggregate -> classify the
#   produced usage_daily row against POST-minus-PRE.
#
# Requires (already set by the probe before sourcing): SCRIPT_DIR, REPO_ROOT,
# and the classify_evidence function.

# shellcheck source=env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=flapjack_regions.sh
source "$SCRIPT_DIR/lib/flapjack_regions.sh"
# shellcheck source=local_seed_contract.sh
source "$SCRIPT_DIR/lib/local_seed_contract.sh"
# shellcheck source=local_db_access.sh
source "$SCRIPT_DIR/lib/local_db_access.sh"
# shellcheck source=process.sh
source "$SCRIPT_DIR/lib/process.sh"

# --- Tunables ---------------------------------------------------------------
LRP_API_PORT="${PLAYWRIGHT_API_PORT:-3001}"
LRP_API_BASE_URL="http://127.0.0.1:${LRP_API_PORT}"
LRP_AGENT_HEALTH_URL="http://127.0.0.1:9091"
LRP_DRIVEN_REGION="$LOCAL_SEED_PRIMARY_INDEX_REGION"
LRP_DRIVEN_INDEX_NAME="$LOCAL_SEED_PRIMARY_INDEX_NAME"
LRP_DRIVE_WRITES="${LRP_DRIVE_WRITES:-5}"
LRP_DRIVE_SEARCHES="${LRP_DRIVE_SEARCHES:-8}"
# Cold `cargo run` builds dominate the live budget; keep readiness generous.
LRP_API_READY_TIMEOUT="${LRP_API_READY_TIMEOUT:-360}"
LRP_HTTP_READY_TIMEOUT="${LRP_HTTP_READY_TIMEOUT:-60}"
# One scrape interval is 30s (start-metering.sh SCRAPE_INTERVAL_SECS); allow
# more than one interval plus the agent's own cold build.
LRP_SCRAPE_TIMEOUT="${LRP_SCRAPE_TIMEOUT:-300}"

# --- Run state (populated as the bracket advances) --------------------------
LRP_EVIDENCE_FILE=""
LRP_CUSTOMER_ID=""
LRP_FLAPJACK_UID=""
LRP_DRIVEN_PORT=""
LRP_FLAPJACK_URL=""
LRP_TARGET_DATE=""
LRP_PROBE_STARTED_AT=""
LRP_CLEARED_BEFORE="false"
LRP_BASELINE_SCRAPE_AT=""
LRP_PRE_SEARCH=""
LRP_PRE_WRITE=""
LRP_POST_SEARCH=""
LRP_POST_WRITE=""
LRP_EXPECTED_SEARCH=""
LRP_EXPECTED_WRITE=""
LRP_ROWS_AFFECTED=""

log() { echo "[local-real-pipeline] $*"; }

# Emit one FAIL status token and a diagnostic, then exit non-zero. The EXIT
# trap performs teardown; this never masquerades a live failure as a verdict.
probe_fail() {
    local reason="$1" detail="$2"
    echo "[local-real-pipeline] FAIL ${reason}: ${detail}" >&2
    printf 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=%s\n' "$reason"
    exit 1
}

# EXIT trap: remove the temp evidence file and always tear the stack down.
pipeline_teardown() {
    local rc=$?
    if [ -n "$LRP_EVIDENCE_FILE" ] && [ -f "$LRP_EVIDENCE_FILE" ]; then
        rm -f "$LRP_EVIDENCE_FILE"
    fi
    log "Tearing down local stack"
    bash "$SCRIPT_DIR/local-dev-down.sh" 1>&2 || true
    return "$rc"
}

# --- Small HTTP / DB helpers ------------------------------------------------
lrp_http_status() {
    curl -s -o /dev/null -w '%{http_code}' "$1" 2>/dev/null
}

lrp_psql_scalar() {
    run_local_psql -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}

# Single-quote values before embedding them in SQL so local env / seed data
# cannot terminate a literal and append a second statement.
lrp_pg_text_literal() {
    local value="$1"
    value="$(printf '%s' "$value" | sed "s/'/''/g")"
    printf "'%s'" "$value"
}

lrp_pg_utc_day_start_expr() {
    local day_literal
    day_literal="$(lrp_pg_text_literal "$1")"
    printf "(%s || ' 00:00:00+00')::timestamptz" "$day_literal"
}

# Canonical UTC timestamp (T...Z with microseconds) accepted by the classifier.
LRP_UTC_TS_FMT='YYYY-MM-DD"T"HH24:MI:SS.US"Z"'

lrp_driven_port() {
    local region_port region port
    for region_port in ${FLAPJACK_REGIONS:-}; do
        region="${region_port%%:*}"
        port="${region_port##*:}"
        if [ "$region" = "$LRP_DRIVEN_REGION" ]; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

lrp_wait_http_ok() {
    local url="$1" name="$2" timeout="$3" deadline
    deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(lrp_http_status "$url")" = "200" ]; then
            return 0
        fi
        sleep 1
    done
    log "timed out after ${timeout}s waiting for ${name} at ${url}"
    return 1
}

lrp_agent_last_scrape_at() {
    curl -s "$LRP_AGENT_HEALTH_URL/health" 2>/dev/null | python3 -c '
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
value = doc.get("last_scrape_at")
print(value if value else "")
' 2>/dev/null
}

# Count distinct nonzero counter event types (search/write) the agent wrote for
# the driven scope inside the target-date window. 2 == both landed.
lrp_scoped_delta_event_types() {
    local sql customer_sql region_sql target_start_expr
    customer_sql="$(lrp_pg_text_literal "$LRP_CUSTOMER_ID")"
    region_sql="$(lrp_pg_text_literal "$LRP_DRIVEN_REGION")"
    target_start_expr="$(lrp_pg_utc_day_start_expr "$LRP_TARGET_DATE")"
    printf -v sql "SELECT count(DISTINCT event_type) FROM usage_records WHERE customer_id=%s AND region=%s AND event_type IN ('search_requests','write_operations') AND value > 0 AND recorded_at >= %s AND recorded_at < (%s + interval '1 day')" \
        "$customer_sql" "$region_sql" "$target_start_expr" "$target_start_expr"
    lrp_psql_scalar "$sql"
}

# Read one flapjack /metrics counter for the driven index UID. Echoes the
# integer value; returns 3 when the counter is absent (fail closed, never 0).
lrp_read_metrics_counter() {
    local metric="$1" body
    body="$(curl -s \
        -H "X-Algolia-API-Key: ${FLAPJACK_ADMIN_KEY}" \
        -H "X-Algolia-Application-Id: flapjack" \
        "$LRP_FLAPJACK_URL/metrics" 2>/dev/null)"
    # Data is passed as argv (not stdin): the heredoc already owns python's
    # stdin as the program text, so a pipe here would be discarded.
    python3 - "$metric" "$LRP_FLAPJACK_UID" "$body" <<'PY'
import re, sys
metric, uid, data = sys.argv[1], sys.argv[2], sys.argv[3]
pattern = re.compile(
    r'^' + re.escape(metric) + r'\{[^}]*index="' + re.escape(uid) + r'"[^}]*\}\s+([0-9]+(?:\.[0-9]+)?)\s*$',
    re.MULTILINE,
)
match = pattern.search(data)
if not match:
    raise SystemExit(3)
print(int(float(match.group(1))))
PY
}

lrp_drive_one_write() {
    local n="$1" payload status
    printf -v payload '{"requests":[{"action":"addObject","body":{"objectID":"probe-%s","title":"probe document %s"}}]}' "$n" "$n"
    status="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        "$LRP_FLAPJACK_URL/1/indexes/$LRP_FLAPJACK_UID/batch" \
        -H "Content-Type: application/json" \
        -H "X-Algolia-API-Key: ${FLAPJACK_ADMIN_KEY}" \
        -H "X-Algolia-Application-Id: flapjack" \
        -d "$payload" 2>/dev/null)"
    case "$status" in 200 | 201 | 202) return 0 ;; *) return 1 ;; esac
}

lrp_drive_one_search() {
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        "$LRP_FLAPJACK_URL/1/indexes/$LRP_FLAPJACK_UID/query" \
        -H "Content-Type: application/json" \
        -H "X-Algolia-API-Key: ${FLAPJACK_ADMIN_KEY}" \
        -H "X-Algolia-Application-Id: flapjack" \
        -d '{"query":"probe"}' 2>/dev/null)"
    case "$status" in 200 | 202) return 0 ;; *) return 1 ;; esac
}

# ===========================================================================
# Bracket stages
# ===========================================================================

# Step 0: prepare and load .env.local; require the multi-region defaults.
lrp_prepare_env() {
    bash "$SCRIPT_DIR/local_demo.sh" --prepare-env-only >&2 \
        || probe_fail env_prep "local_demo.sh --prepare-env-only failed; fix .env.local bootstrap before rerunning"
    load_env_file "$REPO_ROOT/.env.local"
    export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
    [ -n "${DATABASE_URL:-}" ] \
        || probe_fail env_prep "DATABASE_URL missing from .env.local; local Postgres owner must supply it"
    [ -n "${FLAPJACK_REGIONS:-}" ] \
        || probe_fail env_prep "FLAPJACK_REGIONS missing from .env.local; local_demo.sh owns the multi-region default"
    LRP_DRIVEN_PORT="$(lrp_driven_port)" \
        || probe_fail env_prep "FLAPJACK_REGIONS has no ${LRP_DRIVEN_REGION} entry"
    LRP_FLAPJACK_URL="http://127.0.0.1:${LRP_DRIVEN_PORT}"
    require_local_database_access "local real pipeline probe" \
        || probe_fail env_prep "local Postgres access unavailable; start docker compose / host psql before rerunning"
}

# Step 1: bring the stack up, launch the API in the background, seed, and
# assert every configured flapjack region is healthy.
lrp_bring_up_stack() {
    bash "$SCRIPT_DIR/local-dev-up.sh" >&2 \
        || probe_fail stack_up "local-dev-up.sh failed; inspect its Docker/flapjack diagnostics"

    mkdir -p "$REPO_ROOT/.local"
    # api-dev.sh execs the long-running server, so it MUST run in the
    # background. It writes its own .local/api.pid ($$); local-dev-down.sh
    # owns stopping it. INTERNAL_AUTH_TOKEN wires /internal/* auth so the
    # metering agent's tenant-map fetch (INTERNAL_KEY, below) is authorized.
    nohup env \
        INTERNAL_AUTH_TOKEN="${FLAPJACK_ADMIN_KEY}" \
        API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1 \
        LISTEN_ADDR="127.0.0.1:${LRP_API_PORT}" \
        bash "$SCRIPT_DIR/api-dev.sh" </dev/null >"$REPO_ROOT/.local/api.log" 2>&1 &
    echo $! >"$REPO_ROOT/.local/api.pid"

    lrp_wait_http_ok "$LRP_API_BASE_URL/health" "api" "$LRP_API_READY_TIMEOUT" \
        || probe_fail api_health "API never became healthy; see .local/api.log"

    bash "$SCRIPT_DIR/seed_local.sh" >&2 \
        || probe_fail seed "seed_local.sh failed; local seed owner must succeed before metering"

    lrp_assert_flapjack_regions_healthy
}

lrp_assert_flapjack_regions_healthy() {
    local region_port region port url
    for region_port in ${FLAPJACK_REGIONS}; do
        region="${region_port%%:*}"
        port="${region_port##*:}"
        url="http://127.0.0.1:${port}/health"
        if [ "$(lrp_http_status "$url")" != "200" ]; then
            probe_fail flapjack_preflight "flapjack ${region} not healthy at ${url}; local-dev-up.sh likely skipped flapjack (set FLAPJACK_DEV_DIR / build the binary)"
        fi
    done
}

# Step 2: resolve the driven customer + physical UID and require exactly one
# agreeing tenant-map entry.
lrp_resolve_target() {
    LRP_CUSTOMER_ID="$(lrp_psql_scalar "SELECT id FROM customers WHERE billing_plan = 'shared' LIMIT 1")"
    [ -n "$LRP_CUSTOMER_ID" ] \
        || probe_fail resolve_target "no shared-plan customer found; seed_local.sh must create one"
    local customer_hex
    customer_hex="$(printf '%s' "$LRP_CUSTOMER_ID" | tr -d '-' | tr '[:upper:]' '[:lower:]')"
    LRP_FLAPJACK_UID="${customer_hex}_${LRP_DRIVEN_INDEX_NAME}"
    lrp_verify_tenant_map
}

lrp_verify_tenant_map() {
    local body rc
    body="$(curl -s -H "x-internal-key: ${FLAPJACK_ADMIN_KEY}" "$LRP_API_BASE_URL/internal/tenant-map" 2>/dev/null)"
    # Body is passed as argv (not stdin) — the heredoc owns python's stdin.
    python3 - \
        "$LRP_CUSTOMER_ID" "$LRP_DRIVEN_INDEX_NAME" "$LRP_FLAPJACK_UID" "$LRP_DRIVEN_PORT" "$body" <<'PY'
import sys, json
customer, index_name, uid, port = sys.argv[1:5]
try:
    entries = json.loads(sys.argv[5])
except Exception:
    raise SystemExit(2)
if not isinstance(entries, list):
    raise SystemExit(2)
matches = [
    e for e in entries
    if str(e.get("customer_id")) == customer and e.get("tenant_id") == index_name
]
if len(matches) != 1:
    raise SystemExit(3)
entry = matches[0]
if entry.get("flapjack_uid") != uid:
    raise SystemExit(4)
url = entry.get("flapjack_url") or ""
if f"127.0.0.1:{port}" not in url and f"localhost:{port}" not in url:
    raise SystemExit(5)
raise SystemExit(0)
PY
    rc=$?
    case "$rc" in
        0) : ;;
        2) probe_fail tenant_map "tenant-map response was not a JSON array (auth/API failure); x-internal-key must match INTERNAL_AUTH_TOKEN" ;;
        3) probe_fail tenant_map "expected exactly one tenant-map entry for customer=${LRP_CUSTOMER_ID} tenant=${LRP_DRIVEN_INDEX_NAME}" ;;
        4) probe_fail tenant_map "tenant-map flapjack_uid disagrees with computed ${LRP_FLAPJACK_UID}" ;;
        5) probe_fail tenant_map "tenant-map flapjack_url is not the driven region ${LRP_DRIVEN_REGION}:${LRP_DRIVEN_PORT}" ;;
        *) probe_fail tenant_map "tenant-map verification failed (rc=${rc})" ;;
    esac
}

# Step 3a: capture target_date + DB-clock probe_started_at. Shared by positive
# and negative live modes so every evidence document has the same clock source.
lrp_capture_probe_clock() {
    LRP_TARGET_DATE="$(date -u +%F)"
    LRP_PROBE_STARTED_AT="$(lrp_psql_scalar "SELECT to_char(now() AT TIME ZONE 'UTC','${LRP_UTC_TS_FMT}')")"
    [ -n "$LRP_PROBE_STARTED_AT" ] \
        || probe_fail clear_failed "could not read DB clock for probe_started_at"
}

# Step 3b: clear scoped rows and confirm zero scoped rows before setting
# cleared_before.
lrp_clear_target_scope() {
    local sql total customer_sql region_sql target_date_sql target_start_expr
    customer_sql="$(lrp_pg_text_literal "$LRP_CUSTOMER_ID")"
    region_sql="$(lrp_pg_text_literal "$LRP_DRIVEN_REGION")"
    target_date_sql="$(lrp_pg_text_literal "$LRP_TARGET_DATE")"
    target_start_expr="$(lrp_pg_utc_day_start_expr "$LRP_TARGET_DATE")"
    printf -v sql "DELETE FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date" \
        "$customer_sql" "$region_sql" "$target_date_sql"
    run_local_psql -q -c "$sql" >/dev/null 2>&1 \
        || probe_fail clear_failed "usage_daily delete failed"
    printf -v sql "DELETE FROM usage_records WHERE customer_id=%s AND region=%s AND recorded_at >= %s AND recorded_at < (%s + interval '1 day')" \
        "$customer_sql" "$region_sql" "$target_start_expr" "$target_start_expr"
    run_local_psql -q -c "$sql" >/dev/null 2>&1 \
        || probe_fail clear_failed "usage_records delete failed"

    printf -v sql "SELECT (SELECT count(*) FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date) + (SELECT count(*) FROM usage_records WHERE customer_id=%s AND region=%s AND recorded_at >= %s AND recorded_at < (%s + interval '1 day'))" \
        "$customer_sql" "$region_sql" "$target_date_sql" \
        "$customer_sql" "$region_sql" "$target_start_expr" "$target_start_expr"
    total="$(lrp_psql_scalar "$sql")"
    [ "$total" = "0" ] \
        || probe_fail clear_failed "scoped rows remained after delete (count=${total:-unknown})"
    LRP_CLEARED_BEFORE="true"
}

# Step 3: capture target_date + DB-clock probe_started_at, then clear and
# confirm zero scoped rows before setting cleared_before.
lrp_capture_and_clear() {
    lrp_capture_probe_clock
    lrp_clear_target_scope
}

# Step 4: start the agent, await the FIRST (baseline) scrape, then read PRE.
lrp_start_agent_and_read_pre() {
    INTERNAL_KEY="${FLAPJACK_ADMIN_KEY}" bash "$SCRIPT_DIR/start-metering.sh" >&2 \
        || probe_fail agent_baseline "start-metering.sh failed to launch the agent"

    local deadline ts
    deadline=$((SECONDS + LRP_SCRAPE_TIMEOUT))
    ts=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        ts="$(lrp_agent_last_scrape_at)"
        [ -n "$ts" ] && break
        sleep 2
    done
    [ -n "$ts" ] \
        || probe_fail agent_baseline "agent never completed its first scrape (last_scrape_at stayed null)"
    LRP_BASELINE_SCRAPE_AT="$ts"

    LRP_PRE_SEARCH="$(lrp_read_metrics_counter flapjack_search_requests_total)" \
        || probe_fail agent_baseline "flapjack_search_requests_total absent for ${LRP_FLAPJACK_UID} at PRE"
    LRP_PRE_WRITE="$(lrp_read_metrics_counter flapjack_write_operations_total)" \
        || probe_fail agent_baseline "flapjack_write_operations_total absent for ${LRP_FLAPJACK_UID} at PRE"
}

# Step 5: verify the traffic key with one write, then drive KNOWN counts.
lrp_drive_traffic() {
    lrp_drive_one_write 0 \
        || probe_fail traffic "traffic key rejected: verify POST /batch did not succeed"
    local i
    for ((i = 1; i <= LRP_DRIVE_WRITES; i++)); do
        lrp_drive_one_write "$i" \
            || probe_fail traffic "driven write ${i}/${LRP_DRIVE_WRITES} failed"
    done
    for ((i = 1; i <= LRP_DRIVE_SEARCHES; i++)); do
        lrp_drive_one_search \
            || probe_fail traffic "driven search ${i}/${LRP_DRIVE_SEARCHES} failed"
    done
}

# Step 6: await the NEXT scrape (delta rows landed), then read POST and compute
# the expected counters as POST minus PRE.
lrp_await_delta_and_read_post() {
    local deadline ts types
    deadline=$((SECONDS + LRP_SCRAPE_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        ts="$(lrp_agent_last_scrape_at)"
        types="$(lrp_scoped_delta_event_types)"
        if [ -n "$ts" ] && [ "$ts" != "$LRP_BASELINE_SCRAPE_AT" ] && [ "${types:-0}" = "2" ]; then
            break
        fi
        sleep 3
    done
    if [ -z "${ts:-}" ] || [ "$ts" = "$LRP_BASELINE_SCRAPE_AT" ]; then
        probe_fail agent_delta "agent did not scrape again after traffic (last=${ts:-null} baseline=${LRP_BASELINE_SCRAPE_AT}); check agent scrape loop"
    fi
    if [ "${types:-0}" != "2" ]; then
        probe_fail agent_delta "expected both search+write delta rows for ${LRP_FLAPJACK_UID}; got ${types:-0} (tenant-map/auth mismatch or missing counter rows)"
    fi

    LRP_POST_SEARCH="$(lrp_read_metrics_counter flapjack_search_requests_total)" \
        || probe_fail agent_delta "flapjack_search_requests_total absent for ${LRP_FLAPJACK_UID} at POST"
    LRP_POST_WRITE="$(lrp_read_metrics_counter flapjack_write_operations_total)" \
        || probe_fail agent_delta "flapjack_write_operations_total absent for ${LRP_FLAPJACK_UID} at POST"
    [ "$LRP_POST_SEARCH" -ge "$LRP_PRE_SEARCH" ] && [ "$LRP_POST_WRITE" -ge "$LRP_PRE_WRITE" ] \
        || probe_fail agent_delta "counters not monotonic (search ${LRP_PRE_SEARCH}->${LRP_POST_SEARCH}, write ${LRP_PRE_WRITE}->${LRP_POST_WRITE})"
    LRP_EXPECTED_SEARCH=$((LRP_POST_SEARCH - LRP_PRE_SEARCH))
    LRP_EXPECTED_WRITE=$((LRP_POST_WRITE - LRP_PRE_WRITE))
}

# Guard the positive path against date straddle after metered traffic. Negative
# modes drive no traffic and intentionally do not inherit this positive-only
# metering-agent state check.
lrp_guard_no_date_straddle() {
    local sql straddle customer_sql region_sql probe_started_at_sql target_start_expr
    customer_sql="$(lrp_pg_text_literal "$LRP_CUSTOMER_ID")"
    region_sql="$(lrp_pg_text_literal "$LRP_DRIVEN_REGION")"
    probe_started_at_sql="$(lrp_pg_text_literal "$LRP_PROBE_STARTED_AT")"
    target_start_expr="$(lrp_pg_utc_day_start_expr "$LRP_TARGET_DATE")"
    printf -v sql "SELECT count(*) FROM usage_records WHERE customer_id=%s AND region=%s AND recorded_at >= %s::timestamptz AND NOT (recorded_at >= %s AND recorded_at < (%s + interval '1 day'))" \
        "$customer_sql" "$region_sql" "$probe_started_at_sql" "$target_start_expr" "$target_start_expr"
    straddle="$(lrp_psql_scalar "$sql")"
    [ "${straddle:-1}" = "0" ] \
        || probe_fail date_straddle "usage_records straddle the ${LRP_TARGET_DATE} UTC window (out-of-window rows=${straddle})"
}

# Run the real aggregation job once and parse the single rows_affected value
# from the Rust `aggregation complete` event.
lrp_run_aggregation_job() {
    local agg_output
    agg_output="$(bash "$SCRIPT_DIR/run-aggregation-job.sh" "$LRP_TARGET_DATE" 2>&1)" \
        || probe_fail aggregation "run-aggregation-job.sh exited non-zero"
    LRP_ROWS_AFFECTED="$(printf '%s\n' "$agg_output" | python3 -c '
import re, sys
data = sys.stdin.read()
values = set()
for line in data.splitlines():
    if "aggregation complete" in line and "rows_affected=" in line:
        for m in re.finditer(r"rows_affected=(\d+)", line):
            values.add(m.group(1))
if len(values) != 1:
    raise SystemExit(1)
print(values.pop())
')" || probe_fail aggregation "could not parse exactly one rows_affected from the aggregation complete event"
}

# Step 7: stop only the agent, guard against date straddle, aggregate once, and
# parse the single rows_affected value from the Rust `aggregation complete`
# event.
lrp_aggregate() {
    kill_pid_file "$REPO_ROOT/.local/metering-agent-${LRP_DRIVEN_REGION}.pid" \
        "metering-agent-${LRP_DRIVEN_REGION}" "metering-agent" "*metering-agent*"
    lrp_guard_no_date_straddle
    lrp_run_aggregation_job
}

# Step 8: serialize the produced usage_daily row into evidence and classify it.
lrp_build_evidence() {
    local sql row row_present="false" field_count customer_sql region_sql target_date_sql
    local rs="" rw="" ragg="" rcid="" rreg="" rdate=""
    customer_sql="$(lrp_pg_text_literal "$LRP_CUSTOMER_ID")"
    region_sql="$(lrp_pg_text_literal "$LRP_DRIVEN_REGION")"
    target_date_sql="$(lrp_pg_text_literal "$LRP_TARGET_DATE")"
    printf -v sql "SELECT search_requests,write_operations,to_char(aggregated_at AT TIME ZONE 'UTC','%s'),customer_id::text,region,to_char(date,'YYYY-MM-DD') FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date" \
        "$LRP_UTC_TS_FMT" "$customer_sql" "$region_sql" "$target_date_sql"
    row="$(run_local_psql -tAF '|' -c "$sql" 2>/dev/null)" \
        || probe_fail evidence "could not query usage_daily evidence row"
    case "$row" in
        *$'\n'*)
            probe_fail evidence "expected at most one usage_daily evidence row for ${LRP_CUSTOMER_ID}/${LRP_DRIVEN_REGION}/${LRP_TARGET_DATE}"
            ;;
    esac
    if [ -n "$row" ]; then
        field_count="$(printf '%s\n' "$row" | awk -F'|' 'NR==1 { print NF }')"
        [ "$field_count" = "6" ] \
            || probe_fail evidence "usage_daily evidence row had ${field_count:-0} fields; expected 6"
        IFS='|' read -r rs rw ragg rcid rreg rdate <<<"$row"
        [ -n "$rs" ] && [ -n "$rw" ] && [ -n "$ragg" ] && [ -n "$rcid" ] && [ -n "$rreg" ] && [ -n "$rdate" ] \
            || probe_fail evidence "usage_daily evidence row was incomplete"
        row_present="true"
    fi

    python3 - "$LRP_EVIDENCE_FILE" \
        "$LRP_CUSTOMER_ID" "$LRP_DRIVEN_REGION" "$LRP_TARGET_DATE" "$LRP_CLEARED_BEFORE" \
        "$LRP_EXPECTED_SEARCH" "$LRP_EXPECTED_WRITE" "$LRP_PROBE_STARTED_AT" "$LRP_ROWS_AFFECTED" \
        "$row_present" "$rs" "$rw" "$ragg" "$rcid" "$rreg" "$rdate" <<'PY'
import json, sys
(path, customer_id, region, target_date, cleared_before,
 expected_search, expected_write, probe_started_at, rows_affected,
 row_present, rs, rw, ragg, rcid, rreg, rdate) = sys.argv[1:17]
doc = {
    "schema_version": 1,
    "customer_id": customer_id,
    "region": region,
    "target_date": target_date,
    "cleared_before": cleared_before == "true",
    "expected_search": int(expected_search),
    "expected_write": int(expected_write),
    "probe_started_at": probe_started_at,
    "rows_affected": int(rows_affected),
}
if row_present == "true":
    doc["search_requests"] = int(rs)
    doc["write_operations"] = int(rw)
    doc["aggregated_at"] = ragg
    doc["row_customer_id"] = rcid
    doc["row_region"] = rreg
    doc["row_target_date"] = rdate
else:
    for field in ("search_requests", "write_operations", "aggregated_at",
                  "row_customer_id", "row_region", "row_target_date"):
        doc[field] = None
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PY
    [ "$?" -eq 0 ] || probe_fail evidence "could not serialize evidence JSON"
}

lrp_create_evidence_file_and_trap() {
    LRP_EVIDENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/local_real_pipeline_evidence.XXXXXX.json")" \
        || probe_fail env_prep "could not create evidence temp file"
    trap pipeline_teardown EXIT
}

lrp_classify_built_evidence() {
    local classifier_rc
    bash "$SCRIPT_DIR/local_real_pipeline_probe.sh" --assert-evidence "$LRP_EVIDENCE_FILE"
    classifier_rc=$?
    return "$classifier_rc"
}

# ===========================================================================
# Entry point
# ===========================================================================
run_full_local_pipeline() {
    lrp_prepare_env

    lrp_create_evidence_file_and_trap

    lrp_bring_up_stack
    lrp_resolve_target
    lrp_capture_and_clear
    lrp_start_agent_and_read_pre
    lrp_drive_traffic
    lrp_await_delta_and_read_post
    lrp_aggregate
    lrp_build_evidence

    log "PRE  search=${LRP_PRE_SEARCH} write=${LRP_PRE_WRITE}"
    log "POST search=${LRP_POST_SEARCH} write=${LRP_POST_WRITE}"
    log "delta=POST-PRE search=${LRP_EXPECTED_SEARCH} write=${LRP_EXPECTED_WRITE} rows_affected=${LRP_ROWS_AFFECTED}"

    # Classify through the probe's real --assert-evidence CLI surface (subprocess)
    # so the produced evidence passes the same readable-file + arg parsing the
    # Stage 1 classifier owner enforces, and propagate its exit verdict.
    lrp_classify_built_evidence
}

run_negative_seeded_local_pipeline() {
    lrp_prepare_env
    lrp_create_evidence_file_and_trap

    lrp_bring_up_stack
    lrp_resolve_target
    lrp_capture_probe_clock
    LRP_CLEARED_BEFORE="false"
    LRP_EXPECTED_SEARCH="0"
    LRP_EXPECTED_WRITE="0"
    lrp_run_aggregation_job
    lrp_build_evidence

    log "negative-seeded expected search=0 write=0 rows_affected=${LRP_ROWS_AFFECTED} cleared=${LRP_CLEARED_BEFORE}"
    lrp_classify_built_evidence
}

run_negative_nodrive_local_pipeline() {
    lrp_prepare_env
    lrp_create_evidence_file_and_trap

    lrp_bring_up_stack
    lrp_resolve_target
    lrp_capture_and_clear
    LRP_EXPECTED_SEARCH="0"
    LRP_EXPECTED_WRITE="0"
    lrp_run_aggregation_job
    lrp_build_evidence

    log "negative-nodrive expected search=0 write=0 rows_affected=${LRP_ROWS_AFFECTED} cleared=${LRP_CLEARED_BEFORE}"
    lrp_classify_built_evidence
}
