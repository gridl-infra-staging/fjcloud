#!/usr/bin/env bash

# Read-only engine exposure probe. Classifies AWS security-group posture and
# status-only external reachability evidence without capturing response bodies.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/env.sh disable=SC1091
source "$REPO_ROOT/scripts/lib/env.sh"

TARGETS_FILE=""
EVIDENCE_DIR=""
LIVE_EVIDENCE_DIR=""
TARGET_COUNT=0
HAS_EXPOSED=0
HAS_LATENT_EXPOSURE=0
HAS_INDETERMINATE=0
HAS_TRANSPORT_FAILURE=0

usage() {
    cat <<'EOF'
Usage: scripts/security/probe_engine_exposure.sh --targets-file FILE [--evidence-dir DIR]

Targets are tab-separated rows with no header:
  environment<TAB>vm_id<TAB>target_address<TAB>sg_id[,sg_id...]

Without --evidence-dir, the probe collects read-only evidence with AWS CLI,
nc, and curl. --evidence-dir is for hermetic known-answer fixtures only.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --targets-file)
            [ "$#" -ge 2 ] || die "--targets-file requires a path"
            TARGETS_FILE="$2"
            shift 2
            ;;
        --evidence-dir)
            [ "$#" -ge 2 ] || die "--evidence-dir requires a path"
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$TARGETS_FILE" ] || die "--targets-file is required"
[ -f "$TARGETS_FILE" ] || die "targets file not found: $TARGETS_FILE"

if [ -n "$EVIDENCE_DIR" ]; then
    [ -d "$EVIDENCE_DIR" ] || die "evidence directory not found: $EVIDENCE_DIR"
else
    LIVE_EVIDENCE_DIR="$(mktemp -d)" || die "could not create temporary evidence directory"
    EVIDENCE_DIR="$LIVE_EVIDENCE_DIR"
    trap 'rm -rf "$LIVE_EVIDENCE_DIR"' EXIT
fi

if [ -n "$LIVE_EVIDENCE_DIR" ] && [ -n "${FJCLOUD_SECRET_FILE:-}" ]; then
    [ -f "$FJCLOUD_SECRET_FILE" ] || die "FJCLOUD_SECRET_FILE not found"
    load_env_file "$FJCLOUD_SECRET_FILE"
fi

is_valid_ipv4() {
    local address="$1"
    local octet
    local -a octets

    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<< "$address"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -le 255 ] || return 1
    done
}

is_valid_dns_name() {
    local address="$1"
    local label
    local -a labels

    [ "${#address}" -le 253 ] || return 1
    [[ "$address" == *.* ]] || return 1
    [[ ! "$address" =~ ^[0-9.]+$ ]] || return 1
    IFS='.' read -r -a labels <<< "$address"
    [ "${#labels[@]}" -ge 2 ] || return 1
    for label in "${labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

is_valid_target_address() {
    is_valid_ipv4 "$1" || is_valid_dns_name "$1"
}

target_fields_are_valid() {
    [[ "$TARGET_ENV" =~ ^[A-Za-z0-9_-]+$ ]] \
        && [[ "$TARGET_VM_ID" =~ ^i-[A-Za-z0-9-]+$ ]] \
        && is_valid_target_address "$TARGET_ADDRESS" \
        && [[ "$TARGET_SG_IDS" =~ ^sg-[0-9a-f]+(,sg-[0-9a-f]+)*$ ]]
}

target_key() {
    printf '%s_%s\n' "$TARGET_ENV" "$TARGET_VM_ID"
}

write_command_result() {
    local output_file="$1"
    local exit_file="$2"
    shift 2
    local command_output command_exit

    if command_output="$("$@" 2>&1)"; then
        command_exit=0
    else
        command_exit=$?
    fi
    printf '%s\n' "$command_output" > "$output_file"
    printf '%s\n' "$command_exit" > "$exit_file"
}

collect_live_sg_evidence() {
    local -a security_group_ids
    IFS=',' read -r -a security_group_ids <<< "$TARGET_SG_IDS"

    printf 'COMMAND target=%s aws ec2 describe-security-groups --group-ids %s\n' \
        "$TARGET_VM_ID" "$TARGET_SG_IDS"
    write_command_result \
        "$EVIDENCE_DIR/${TARGET_KEY}.sg.json" \
        "$EVIDENCE_DIR/${TARGET_KEY}.sg.exit" \
        aws ec2 describe-security-groups --group-ids "${security_group_ids[@]}" --output json
    printf 'SG_EVIDENCE target=%s exit=%s\n' \
        "$TARGET_VM_ID" "$(cat "$EVIDENCE_DIR/${TARGET_KEY}.sg.exit")"
}

collect_live_nc_evidence() {
    printf 'COMMAND target=%s nc -zv %s 7700\n' "$TARGET_VM_ID" "$TARGET_ADDRESS"
    write_command_result \
        "$EVIDENCE_DIR/${TARGET_KEY}.nc.output" \
        "$EVIDENCE_DIR/${TARGET_KEY}.nc.exit" \
        nc -zv "$TARGET_ADDRESS" 7700
    printf 'NC_EVIDENCE target=%s exit=%s output=%s\n' \
        "$TARGET_VM_ID" \
        "$(cat "$EVIDENCE_DIR/${TARGET_KEY}.nc.exit")" \
        "$(tr '\n' ' ' < "$EVIDENCE_DIR/${TARGET_KEY}.nc.output")"
}

collect_live_http_evidence() {
    local path_key="$1"
    local request_path="$2"
    local status_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.status"
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.exit"
    local http_status http_exit

    printf 'COMMAND target=%s curl -sS -m 8 -o /dev/null -w %%{http_code} http://%s:7700%s\n' \
        "$TARGET_VM_ID" "$TARGET_ADDRESS" "$request_path"
    if http_status="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' \
        "http://${TARGET_ADDRESS}:7700${request_path}" 2>/dev/null)"; then
        http_exit=0
    else
        http_exit=$?
    fi
    printf '%s\n' "$http_status" > "$status_file"
    printf '%s\n' "$http_exit" > "$exit_file"
    printf 'HTTP_EVIDENCE target=%s path=%s status=%s exit=%s\n' \
        "$TARGET_VM_ID" "$request_path" "$http_status" "$http_exit"
}

collect_live_tls_evidence() {
    local status_file="$EVIDENCE_DIR/${TARGET_KEY}.tls.status"
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.tls.exit"
    local verify_file="$EVIDENCE_DIR/${TARGET_KEY}.tls.verify"
    local tls_metrics tls_status tls_verify tls_exit

    printf 'COMMAND target=%s curl -sS -m 8 -o /dev/null -w status/verify https://%s/1/indexes\n' \
        "$TARGET_VM_ID" "$TARGET_ADDRESS"
    if tls_metrics="$(curl -sS -m 8 -o /dev/null \
        -w $'%{http_code}\\t%{ssl_verify_result}' \
        "https://${TARGET_ADDRESS}/1/indexes" 2>/dev/null)"; then
        tls_exit=0
    else
        tls_exit=$?
    fi
    IFS=$'\t' read -r tls_status tls_verify <<< "$tls_metrics"
    printf '%s\n' "${tls_status:-missing}" > "$status_file"
    printf '%s\n' "$tls_exit" > "$exit_file"
    printf '%s\n' "${tls_verify:-missing}" > "$verify_file"
    printf 'TLS_EVIDENCE target=%s status=%s exit=%s verify=%s\n' \
        "$TARGET_VM_ID" "${tls_status:-missing}" "$tls_exit" "${tls_verify:-missing}"
}

collect_live_evidence() {
    collect_live_sg_evidence
    collect_live_nc_evidence
    collect_live_http_evidence dashboard /dashboard
    collect_live_http_evidence swagger_ui /swagger-ui
    collect_live_http_evidence indexes /1/indexes
    collect_live_tls_evidence
}

classify_security_group() {
    local json_file="$EVIDENCE_DIR/${TARGET_KEY}.sg.json"
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.sg.exit"
    local command_exit

    [ -f "$json_file" ] && [ -f "$exit_file" ] || { printf 'indeterminate\n'; return; }
    command_exit="$(cat "$exit_file")"
    [[ "$command_exit" =~ ^[0-9]+$ ]] && [ "$command_exit" -eq 0 ] \
        || { printf 'indeterminate\n'; return; }

    python3 - "$json_file" "$TARGET_SG_IDS" <<'PY' 2>/dev/null || printf 'indeterminate\n'
import json
import sys

path, expected_csv = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

groups = payload.get("SecurityGroups") if isinstance(payload, dict) else None
if not isinstance(groups, list) or not groups:
    raise SystemExit(1)

expected = set(expected_csv.split(","))
returned = {group.get("GroupId") for group in groups if isinstance(group, dict)}
if returned != expected:
    raise SystemExit(1)

is_public = False
for group in groups:
    permissions = group.get("IpPermissions")
    if not isinstance(permissions, list):
        raise SystemExit(1)
    for permission in permissions:
        if not isinstance(permission, dict):
            raise SystemExit(1)
        protocol = permission.get("IpProtocol")
        if protocol not in {"tcp", "-1"}:
            continue
        if protocol == "tcp":
            start, end = permission.get("FromPort"), permission.get("ToPort")
            if not isinstance(start, int) or not isinstance(end, int):
                raise SystemExit(1)
            if not start <= 7700 <= end:
                continue
        ranges = permission.get("IpRanges", [])
        if not isinstance(ranges, list) or any(not isinstance(item, dict) for item in ranges):
            raise SystemExit(1)
        if any(item.get("CidrIp") == "0.0.0.0/0" for item in ranges):
            is_public = True

print("public" if is_public else "restricted")
PY
}

classify_nc() {
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.nc.exit"
    local output_file="$EVIDENCE_DIR/${TARGET_KEY}.nc.output"
    local nc_exit nc_output normalized_output

    [ -f "$exit_file" ] && [ -f "$output_file" ] || { printf 'indeterminate\n'; return; }
    nc_exit="$(cat "$exit_file")"
    nc_output="$(cat "$output_file")"
    [[ "$nc_exit" =~ ^[0-9]+$ ]] && [ -n "$nc_output" ] \
        || { printf 'indeterminate\n'; return; }
    if [ "$nc_exit" -eq 0 ]; then
        printf 'open\n'
        return
    fi

    normalized_output="$(LC_ALL=C printf '%s' "$nc_output" | tr '[:upper:]' '[:lower:]')"
    if [ "$nc_exit" -ne 1 ]; then
        printf 'indeterminate\n'
    elif [[ "$normalized_output" == *"timed out"* ]] \
        || [[ "$normalized_output" == *"timeout"* ]]; then
        printf 'timeout\n'
    elif [[ "$normalized_output" == *"connection refused"* ]]; then
        printf 'closed\n'
    else
        printf 'indeterminate\n'
    fi
}

classify_http() {
    local path_key="$1"
    local status_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.status"
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.exit"
    local http_status http_exit

    [ -f "$status_file" ] && [ -f "$exit_file" ] \
        || { printf 'indeterminate\n'; return; }
    http_status="$(cat "$status_file")"
    http_exit="$(cat "$exit_file")"
    [[ "$http_exit" =~ ^[0-9]+$ ]] || { printf 'indeterminate\n'; return; }
    if [ "$http_status" = "200" ]; then
        printf 'exposed\n'
    elif [ "$http_status" = "000" ] && [ "$http_exit" -ne 0 ]; then
        printf 'not_exposed\n'
    elif [[ "$http_status" =~ ^[1-5][0-9][0-9]$ ]] && [ "$http_exit" -eq 0 ]; then
        printf 'not_exposed\n'
    else
        printf 'indeterminate\n'
    fi
}

http_request_reached_target() {
    local path_key="$1"
    local status_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.status"
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.exit"
    local http_status http_exit

    [ -f "$status_file" ] && [ -f "$exit_file" ] || return 1
    http_status="$(cat "$status_file")"
    http_exit="$(cat "$exit_file")"
    [[ "$http_status" =~ ^[1-5][0-9][0-9]$ ]] \
        && [[ "$http_exit" =~ ^[0-9]+$ ]] \
        && [ "$http_exit" -eq 0 ]
}

classify_tls() {
    local status_file="$EVIDENCE_DIR/${TARGET_KEY}.tls.status"
    local exit_file="$EVIDENCE_DIR/${TARGET_KEY}.tls.exit"
    local verify_file="$EVIDENCE_DIR/${TARGET_KEY}.tls.verify"
    local tls_status tls_exit tls_verify

    [ -f "$status_file" ] && [ -f "$exit_file" ] && [ -f "$verify_file" ] \
        || { printf 'PROBE_UNREACHABLE\n'; return; }
    tls_status="$(cat "$status_file")"
    tls_exit="$(cat "$exit_file")"
    tls_verify="$(cat "$verify_file")"
    [[ "$tls_exit" =~ ^[0-9]+$ ]] && [[ "$tls_verify" =~ ^[0-9]+$ ]] \
        || { printf 'PROBE_UNREACHABLE\n'; return; }

    if [ "$tls_exit" -eq 0 ] && [ "$tls_verify" -eq 0 ] \
        && [[ "$tls_status" =~ ^[1-5][0-9][0-9]$ ]]; then
        printf 'TLS_OK\n'
    elif [ "$tls_verify" -ne 0 ] || [ "$tls_exit" -eq 35 ] \
        || [ "$tls_exit" -eq 51 ] || [ "$tls_exit" -eq 60 ]; then
        printf 'TLS_UNTRUSTED\n'
    elif http_request_reached_target indexes; then
        printf 'TLS_ABSENT\n'
    else
        printf 'PROBE_UNREACHABLE\n'
    fi
}

read_http_status() {
    local path_key="$1"
    local status_file="$EVIDENCE_DIR/${TARGET_KEY}.http_${path_key}.status"
    [ -f "$status_file" ] && tr -d '\r\n' < "$status_file" || printf 'missing'
}

render_target_verdict() {
    local target_verdict="$1"
    printf 'TARGET env=%s vm_id=%s target_address=%s sg_ids=%s sg_public_7700=%s port=%s dashboard=%s swagger_ui=%s indexes=%s tls=%s verdict=%s\n' \
        "$TARGET_ENV" "$TARGET_VM_ID" "$TARGET_ADDRESS" "$TARGET_SG_IDS" \
        "$SG_STATE" "$NC_STATE" \
        "$(read_http_status dashboard)" "$(read_http_status swagger_ui)" \
        "$(read_http_status indexes)" "$TLS_STATE" "$target_verdict"
}

classify_target() {
    local dashboard_state swagger_state indexes_state target_verdict

    SG_STATE="$(classify_security_group)"
    NC_STATE="$(classify_nc)"
    dashboard_state="$(classify_http dashboard)"
    swagger_state="$(classify_http swagger_ui)"
    indexes_state="$(classify_http indexes)"
    TLS_STATE="$(classify_tls)"
    if [ "$TLS_STATE" != "TLS_OK" ]; then
        HAS_TRANSPORT_FAILURE=1
    fi

    if [ "$dashboard_state" = "exposed" ] \
        || [ "$swagger_state" = "exposed" ] \
        || [ "$indexes_state" = "exposed" ]; then
        target_verdict="EXPOSED"
        HAS_EXPOSED=1
    elif [ "$SG_STATE" = "public" ] && [ "$NC_STATE" = "open" ]; then
        target_verdict="EXPOSED"
        HAS_EXPOSED=1
    elif [ "$SG_STATE" = "public" ]; then
        # A public-SG timeout is still exposed: SG posture creates customer risk on the next engine start.
        target_verdict="EXPOSED (latent: public security group on tcp/7700; engine not reachable)"
        HAS_LATENT_EXPOSURE=1
    elif [ "$NC_STATE" = "open" ]; then
        target_verdict="INDETERMINATE"
        HAS_INDETERMINATE=1
    elif [ "$SG_STATE" = "indeterminate" ] \
        || [ "$NC_STATE" = "indeterminate" ] \
        || [ "$dashboard_state" = "indeterminate" ] \
        || [ "$swagger_state" = "indeterminate" ] \
        || [ "$indexes_state" = "indeterminate" ]; then
        target_verdict="INDETERMINATE"
        HAS_INDETERMINATE=1
    else
        target_verdict="NOT_EXPOSED"
    fi

    render_target_verdict "$target_verdict"
}

mark_invalid_target() {
    printf 'TARGET env=%s vm_id=%s target_address=%s sg_ids=%s tls=PROBE_UNREACHABLE verdict=INDETERMINATE reason=invalid_target_fields\n' \
        "$TARGET_ENV" "$TARGET_VM_ID" "$TARGET_ADDRESS" "$TARGET_SG_IDS"
    HAS_INDETERMINATE=1
    HAS_TRANSPORT_FAILURE=1
}

while IFS=$'\t' read -r TARGET_ENV TARGET_VM_ID TARGET_ADDRESS TARGET_SG_IDS EXTRA_FIELD \
    || [ -n "${TARGET_ENV}${TARGET_VM_ID}${TARGET_ADDRESS}${TARGET_SG_IDS}${EXTRA_FIELD}" ]; do
    [ -n "${TARGET_ENV}${TARGET_VM_ID}${TARGET_ADDRESS}${TARGET_SG_IDS}${EXTRA_FIELD}" ] || continue
    TARGET_COUNT=$((TARGET_COUNT + 1))
    if [ -n "$EXTRA_FIELD" ] || ! target_fields_are_valid; then
        mark_invalid_target
        continue
    fi
    TARGET_KEY="$(target_key)"
    if [ -n "$LIVE_EVIDENCE_DIR" ]; then
        collect_live_evidence
    fi
    classify_target
done < "$TARGETS_FILE"

if [ "$TARGET_COUNT" -eq 0 ]; then
    printf 'VERDICT: VACUOUS (no targets supplied)\n'
    exit 1
elif [ "$HAS_EXPOSED" -eq 1 ]; then
    printf 'VERDICT: EXPOSED\n'
    exit 1
elif [ "$HAS_LATENT_EXPOSURE" -eq 1 ]; then
    printf 'VERDICT: EXPOSED (latent: public security group on tcp/7700; engine not reachable)\n'
    exit 1
elif [ "$HAS_INDETERMINATE" -eq 1 ]; then
    printf 'VERDICT: INDETERMINATE\n'
    exit 1
elif [ "$HAS_TRANSPORT_FAILURE" -eq 1 ]; then
    printf 'VERDICT: TRANSPORT_FAILURE\n'
    exit 1
else
    printf 'VERDICT: NOT_EXPOSED\n'
    exit 0
fi
