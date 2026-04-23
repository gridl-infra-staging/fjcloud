#!/usr/bin/env bash
# local-signoff.sh — Top-level orchestrator that delegates to commerce,
# cold-storage, and HA proof-owner scripts in strict order.
#
# Does NOT duplicate proof-owner internals — only calls the three scripts
# and interprets exit codes/output. Emits its own summary schema with
# per-proof status (pass/fail/not_run) and blocker classification.
#
# Usage:
#   ./scripts/local-signoff.sh [--only {commerce|cold-storage|ha}]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# Source for utility functions only (validation_json_escape, validation_ms_now).
# The orchestrator summary schema differs from the proof-level step format.
source "$SCRIPT_DIR/lib/validation_json.sh"
# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
# shellcheck source=lib/flapjack_regions.sh
source "$SCRIPT_DIR/lib/flapjack_regions.sh"

log() { echo "[local-signoff] $*"; }
die() { echo "[local-signoff] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Proof definitions — indices: 0=commerce, 1=cold-storage, 2=ha
# ---------------------------------------------------------------------------

PROOF_NAMES_0="commerce"
PROOF_NAMES_1="cold-storage"
PROOF_NAMES_2="ha"
PROOF_COUNT=3

# Proof state — parallel scalar variables (bash 3.2 compatible)
PROOF_STATUS_0="not_run"
PROOF_STATUS_1="not_run"
PROOF_STATUS_2="not_run"
PROOF_FAIL_CLASS_0=""
PROOF_FAIL_CLASS_1=""
PROOF_FAIL_CLASS_2=""
PROOF_FAIL_MSG_0=""
PROOF_FAIL_MSG_1=""
PROOF_FAIL_MSG_2=""

ONLY_PROOF=""
CHECK_PREREQUISITES=0
ARTIFACT_DIR=""

# ---------------------------------------------------------------------------
# Proof state accessors (bash 3.2 compatible — no associative arrays)
# ---------------------------------------------------------------------------

proof_name() { eval echo "\$PROOF_NAMES_$1"; }
get_proof_status() { eval echo "\$PROOF_STATUS_$1"; }
set_proof_status() { eval "PROOF_STATUS_$1=\"$2\""; }
set_proof_fail_class() { eval "PROOF_FAIL_CLASS_$1=\"$2\""; }
get_proof_fail_class() { eval echo "\$PROOF_FAIL_CLASS_$1"; }

set_proof_fail_msg() {
    # Store failure message in a temp file to avoid eval quoting issues
    local idx="$1"
    echo "$2" > "$ARTIFACT_DIR/.fail_msg_${idx}"
}

get_proof_fail_msg() {
    local idx="$1"
    if [ -f "$ARTIFACT_DIR/.fail_msg_${idx}" ]; then
        cat "$ARTIFACT_DIR/.fail_msg_${idx}"
    fi
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

usage() {
    echo "Usage: local-signoff.sh [--only {commerce|cold-storage|ha}] [--check-prerequisites]" >&2
}

parse_only_arg() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --only)
                [ "$#" -lt 2 ] && die "--only requires a value"
                ONLY_PROOF="$2"
                case "$ONLY_PROOF" in
                    commerce|cold-storage|ha) ;;
                    *) die "Invalid --only value: $ONLY_PROOF (valid: commerce, cold-storage, ha)" ;;
                esac
                shift 2
                ;;
            --check-prerequisites)
                CHECK_PREREQUISITES=1
                shift
                ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Env preflight — union surface of commerce + cold-storage + HA requirements
# ---------------------------------------------------------------------------

strict_env_issue() {
    local kind="$1" name="$2"
    printf '%s:%s\n' "$kind" "$name"
}

is_valid_flapjack_regions() {
    local regions="$1"
    # Delegate FLAPJACK_REGIONS parsing to the canonical topology helper used
    # by seed/local region-resolution. Suppress helper stderr so strict
    # preflight output stays constrained to reason-code lines.
    FLAPJACK_SINGLE_INSTANCE="" FLAPJACK_REGIONS="$regions" \
        resolve_seed_vm_regions >/dev/null 2>&1
}

is_valid_database_url() {
    local database_url="$1"
    [[ "$database_url" =~ ^postgres(ql)?://[^[:space:]]+$ ]]
}

collect_strict_signoff_env_issues() {
    if [ -z "${STRIPE_LOCAL_MODE:-}" ]; then
        strict_env_issue missing STRIPE_LOCAL_MODE
    elif [ "${STRIPE_LOCAL_MODE}" != "1" ]; then
        strict_env_issue malformed STRIPE_LOCAL_MODE
    fi

    [ -n "${MAILPIT_API_URL:-}" ] || strict_env_issue missing MAILPIT_API_URL
    [ -n "${STRIPE_WEBHOOK_SECRET:-}" ] || strict_env_issue missing STRIPE_WEBHOOK_SECRET
    [ -n "${COLD_STORAGE_ENDPOINT:-}" ] || strict_env_issue missing COLD_STORAGE_ENDPOINT
    [ -n "${COLD_STORAGE_BUCKET:-}" ] || strict_env_issue missing COLD_STORAGE_BUCKET
    [ -n "${COLD_STORAGE_REGION:-}" ] || strict_env_issue missing COLD_STORAGE_REGION
    [ -n "${COLD_STORAGE_ACCESS_KEY:-}" ] || strict_env_issue missing COLD_STORAGE_ACCESS_KEY
    [ -n "${COLD_STORAGE_SECRET_KEY:-}" ] || strict_env_issue missing COLD_STORAGE_SECRET_KEY

    if [ -z "${FLAPJACK_REGIONS:-}" ]; then
        strict_env_issue missing FLAPJACK_REGIONS
    elif ! is_valid_flapjack_regions "$FLAPJACK_REGIONS"; then
        strict_env_issue malformed FLAPJACK_REGIONS
    fi

    if [ -z "${DATABASE_URL:-}" ]; then
        strict_env_issue missing DATABASE_URL
    elif ! is_valid_database_url "$DATABASE_URL"; then
        strict_env_issue malformed DATABASE_URL
    fi

    if [ -n "${SKIP_EMAIL_VERIFICATION:-}" ]; then
        strict_env_issue forbidden SKIP_EMAIL_VERIFICATION
    fi
}

require_strict_signoff_env() {
    local issues issue
    local details=""

    issues="$(collect_strict_signoff_env_issues)"
    [ -z "$issues" ] && return 0

    while IFS= read -r issue; do
        [ -n "$issue" ] || continue
        details="${details} ${issue##*:}(${issue%%:*})"
    done <<EOF
$issues
EOF

    die "Strict signoff prerequisites invalid:${details}"
}

check_prerequisites() {
    local ok=true
    local cmd

    for cmd in docker curl jq; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log "prerequisite ok: $cmd"
        else
            log "ERROR: missing:$cmd"
            ok=false
        fi
    done

    local issue
    while IFS= read -r issue; do
        [ -n "$issue" ] || continue
        log "ERROR: $issue"
        ok=false
    done < <(collect_strict_signoff_env_issues)

    local flapjack_bin
    flapjack_bin="$(find_restart_ready_flapjack_binary || true)"

    if [ -n "$flapjack_bin" ] && [ -x "$flapjack_bin" ]; then
        log "prerequisite ok: flapjack_binary"
    else
        log "ERROR: missing:flapjack_binary"
        ok=false
    fi

    if [ "$ok" = true ]; then
        log "All prerequisites satisfied"
        return 0
    fi

    echo "REASON: prerequisite_missing" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Region resolution
# ---------------------------------------------------------------------------

resolve_ha_region() {
    local first_entry="${FLAPJACK_REGIONS%%,*}"
    printf '%s\n' "${first_entry%%:*}"
}

# ---------------------------------------------------------------------------
# Artifact directory
# ---------------------------------------------------------------------------

init_artifact_dir() {
    ARTIFACT_DIR="${TMPDIR:-/tmp}/fjcloud-local-signoff-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$ARTIFACT_DIR"
}

# ---------------------------------------------------------------------------
# Failure classification
# ---------------------------------------------------------------------------

classify_failure() {
    local output="$1"
    if echo "$output" | grep -qi "harness\|mock\|stub\|not.found\|no.such.file"; then
        echo "local_harness_gap"
    elif echo "$output" | grep -qi "credential\|auth.*fail\|api.key\|secret\|token.*invalid"; then
        echo "live_credential_required"
    elif echo "$output" | grep -qi "deferred\|not.implemented\|intentional"; then
        echo "intentional_product_deferral"
    else
        echo "test_or_proof_failure"
    fi
}

# ---------------------------------------------------------------------------
# Proof delegation
# ---------------------------------------------------------------------------

run_proof() {
    local idx="$1" script_path="$2"
    shift 2

    local output="" exit_code=0
    output=$(bash "$script_path" "$@" 2>&1) || exit_code=$?

    # Persist captured output as stable artifact
    local safe_name
    safe_name="$(proof_name "$idx")"
    safe_name="${safe_name//-/_}"
    echo "$output" > "$ARTIFACT_DIR/${safe_name}.log"

    if [ "$exit_code" -eq 0 ]; then
        set_proof_status "$idx" "pass"
    else
        set_proof_status "$idx" "fail"
        set_proof_fail_msg "$idx" "$output"
        set_proof_fail_class "$idx" "$(classify_failure "$output")"
    fi

    return "$exit_code"
}

refresh_ha_seed_state() {
    local idx="$1"
    local seed_script="$SCRIPT_DIR/seed_local.sh"

    [ -x "$seed_script" ] || return 0

    local output="" exit_code=0
    output=$(bash "$seed_script" 2>&1) || exit_code=$?
    echo "$output" > "$ARTIFACT_DIR/ha_seed.log"

    if [ "$exit_code" -ne 0 ]; then
        set_proof_status "$idx" "fail"
        set_proof_fail_msg "$idx" "$output"
        set_proof_fail_class "$idx" "$(classify_failure "$output")"
        return 1
    fi

    return 0
}

post_ha_api_url() {
    printf '%s\n' "${API_URL:-${API_BASE_URL:-http://localhost:3001}}"
}

set_post_ha_failure() {
    local idx="$1" message="$2"

    log "$message"
    set_proof_status "$idx" "fail"
    set_proof_fail_msg "$idx" "$message"
    set_proof_fail_class "$idx" "test_or_proof_failure"
}

verify_post_ha_health() {
    local idx="$1"
    local api_url
    api_url="$(post_ha_api_url)"

    # HA is intentionally destructive to the local Flapjack process it targets.
    # The orchestrator owns the final local-stack invariant, so a successful HA
    # proof is not enough unless the API and every configured local region are
    # reachable again before the run is marked green.
    if ! curl -sf "${api_url}/health" >/dev/null 2>&1; then
        set_post_ha_failure "$idx" "post-HA health check failed: API ${api_url}/health"
        return 1
    fi

    local region_port region port
    for region_port in $FLAPJACK_REGIONS; do
        region="${region_port%%:*}"
        port="${region_port##*:}"
        if ! curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            set_post_ha_failure "$idx" "post-HA health check failed: flapjack-${region} http://127.0.0.1:${port}/health"
            return 1
        fi
    done

    return 0
}

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------

write_summary_json() {
    local overall="$1"
    local proofs_json=""
    local i=0

    while [ "$i" -lt "$PROOF_COUNT" ]; do
        local name status entry
        name="$(proof_name "$i")"
        status="$(get_proof_status "$i")"

        if [ "$status" = "fail" ]; then
            local raw_msg fclass escaped_msg escaped_class
            raw_msg="$(get_proof_fail_msg "$i")"
            fclass="$(get_proof_fail_class "$i")"
            escaped_msg=$(validation_json_escape "$raw_msg")
            escaped_class=$(validation_json_escape "$fclass")
            entry="{\"name\":\"${name}\",\"status\":\"fail\",\"failure_class\":${escaped_class},\"failure_message\":${escaped_msg}}"
        else
            entry="{\"name\":\"${name}\",\"status\":\"${status}\"}"
        fi

        if [ -z "$proofs_json" ]; then
            proofs_json="$entry"
        else
            proofs_json="${proofs_json},${entry}"
        fi
        i=$((i + 1))
    done

    printf '{"overall":"%s","proofs":[%s],"artifact_dir":"%s"}\n' \
        "$overall" "$proofs_json" "$ARTIFACT_DIR" > "$ARTIFACT_DIR/summary.json"
}

print_human_summary() {
    local overall="$1"
    local i=0

    echo ""
    echo "=== Local Signoff Summary ==="
    while [ "$i" -lt "$PROOF_COUNT" ]; do
        local name status label
        name="$(proof_name "$i")"
        status="$(get_proof_status "$i")"
        case "$status" in
            pass)    label="PASS" ;;
            fail)    label="FAIL" ;;
            not_run) label="SKIP" ;;
        esac
        printf "  %-15s %s\n" "$name" "$label"
        i=$((i + 1))
    done
    echo ""
    if [ "$overall" = "pass" ]; then
        echo "Overall: PASS"
    else
        echo "Overall: FAIL"
    fi
    echo "Artifacts: $ARTIFACT_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_only_arg "$@"
    # Match the other local wrappers: repo-local .env.local provides the default
    # strict-signoff inputs, while explicitly exported shell variables still win.
    load_env_file "$REPO_ROOT/.env.local"

    if [ "$CHECK_PREREQUISITES" = "1" ]; then
        check_prerequisites || exit 1
        return 0
    fi

    require_strict_signoff_env
    init_artifact_dir

    local ha_region
    ha_region="$(resolve_ha_region)"

    local overall="pass"
    local i=0

    while [ "$i" -lt "$PROOF_COUNT" ]; do
        local name script_path
        name="$(proof_name "$i")"

        # Skip non-selected proofs when --only is active
        if [ -n "$ONLY_PROOF" ] && [ "$name" != "$ONLY_PROOF" ]; then
            i=$((i + 1))
            continue
        fi

        case "$name" in
            commerce)     script_path="$SCRIPT_DIR/local-signoff-commerce.sh" ;;
            cold-storage) script_path="$SCRIPT_DIR/local-signoff-cold-storage.sh" ;;
            ha)           script_path="$SCRIPT_DIR/chaos/ha-failover-proof.sh" ;;
        esac

        if [ "$name" = "ha" ]; then
            refresh_ha_seed_state "$i" || { overall="fail"; break; }
            run_proof "$i" "$script_path" "$ha_region" || { overall="fail"; break; }
            verify_post_ha_health "$i" || { overall="fail"; break; }
        else
            run_proof "$i" "$script_path" || { overall="fail"; break; }
        fi

        i=$((i + 1))
    done

    write_summary_json "$overall"
    print_human_summary "$overall"

    if [ "$overall" = "fail" ]; then
        exit 1
    fi
}

main "$@"
