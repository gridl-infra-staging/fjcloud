#!/usr/bin/env bash
# scripts/probe_flapjack_build_identity.sh — canonical Flapjack build-identity
# evidence probe.
#
# Inspects the INSTALLED executable bytes and the process-reported runtime
# identity, then classifies the observation through the Stage 1 identity owners.
# It owns no comparison logic of its own: binary SHA-256 comes from
# scripts/lib/flapjack_binary.sh::flapjack_binary_sha256 and runtime `/health`
# comparison comes from scripts/lib/local_stack_contract.sh
# (flapjack_runtime_identity_reason for the live URL path,
# flapjack_classify_health_json for out-of-band SSM-collected health).
#
# Read-only. Never mutates cloud state, AMIs, migrations, or deployments.
# Emits a single machine-parseable JSON classification line on stdout; all
# human-readable context goes to stderr. No secrets and no absolute worktree
# paths are emitted in the structured artifact.
#
# Classifications (also encoded in the exit code):
#   pass         (0) installed bytes + runtime identity exactly match the
#                    Stage 1 expected identity
#   real_defect  (1) immutable installed-byte or runtime identity mismatch
#   setup_infra  (2) missing AWS/SSM/manifest prerequisites to gather evidence
#   investigate  (3) malformed or internally inconsistent evidence
#
# Usage:
#   scripts/probe_flapjack_build_identity.sh --env local|staging|prod
#
# Env seams (production defaults resolve the real host/binary; tests inject):
#   FLAPJACK_PROBE_LOCAL_BINARY  installed local binary path (default: resolver)
#   FLAPJACK_URL                 local engine base url for /health
#   FLAPJACK_PROBE_SSM_EXEC      remote exec wrapper (default: ssm_exec_staging.sh)
#   FJCLOUD_FLAPJACK_VERSION / FJCLOUD_FLAPJACK_REQUIRED_{REVISION,BUILD_ID,SHA256}
#                                Stage 1 expected identity (manifest/env contract)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
# shellcheck source=lib/local_stack_contract.sh
source "$SCRIPT_DIR/lib/local_stack_contract.sh"

log() { echo "[probe-flapjack-build-identity] $*" >&2; }

usage() {
    cat >&2 <<'USAGE'
Usage: probe_flapjack_build_identity.sh --env local|staging|prod
USAGE
}

PROBE_ENV=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            PROBE_ENV="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            log "unknown argument: $1"
            exit 64
            ;;
    esac
done

case "$PROBE_ENV" in
    local|staging|prod) ;;
    *) usage; exit 64 ;;
esac

# emit_result <classification> <reason> <installed_sha> <expected_sha> <version> <detail>
# Writes the single structured JSON artifact line and exits with the matching
# code. Field values are scalars only — never a filesystem path — so the artifact
# is safe for public live-state mirrors.
emit_result() {
    local classification="$1" reason="$2" installed_sha="$3" expected_sha="$4" version="$5" detail="$6"
    python3 - "$PROBE_ENV" "$classification" "$reason" "$installed_sha" "$expected_sha" "$version" "$detail" <<'PY'
import json
import sys

env, classification, reason, installed_sha, expected_sha, version, detail = sys.argv[1:8]
print(json.dumps({
    "probe": "flapjack_build_identity",
    "env": env,
    "classification": classification,
    "reason": reason,
    "installed_sha256": installed_sha,
    "expected_sha256": expected_sha,
    "runtime_version": version,
    "detail": detail,
}, sort_keys=True))
PY
    case "$classification" in
        pass) exit 0 ;;
        real_defect) exit 1 ;;
        setup_infra) exit 2 ;;
        investigate) exit 3 ;;
        *) exit 3 ;;
    esac
}

# classify_evidence maps gathered evidence onto the four stable classifications.
# It is the single decision table both modes feed. Precedence, highest first:
#   investigate  malformed/unreachable runtime health, or internally
#                inconsistent host evidence (installed bytes vs build-info)
#   real_defect  a concrete runtime identity mismatch, or installed bytes that
#                do not match the Stage 1 expected sha256
#   pass         runtime matches and installed bytes match expected
classify_evidence() {
    local reason="$1" installed_sha="$2" expected_sha="$3" build_info_sha="$4"
    python3 - "$reason" "$installed_sha" "$expected_sha" "$build_info_sha" <<'PY'
import sys

reason, installed_sha, expected_sha, build_info_sha = sys.argv[1:5]

concrete_mismatch = {
    "version_mismatch",
    "revision_mismatch",
    "build_id_mismatch",
    "checksum_mismatch",
    "dirty_local_build",
    "missing_capability",
}

# Internally inconsistent: the binary's own build-info self-report disagrees with
# the bytes actually installed on disk. Evidence cannot be trusted → investigate.
inconsistent = bool(build_info_sha) and bool(installed_sha) and build_info_sha != installed_sha

if reason in {"legacy_malformed_health", "runtime_unreachable"} or inconsistent:
    print("investigate")
elif reason in concrete_mismatch:
    print("real_defect")
elif expected_sha and installed_sha and installed_sha != expected_sha:
    print("real_defect")
elif reason == "match":
    print("pass")
else:
    print("investigate")
PY
}

expected_identity_present() {
    [ -n "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" ] || return 1
    [ -n "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" ] || return 1
    [ -n "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" ] || return 1
    return 0
}

# json_string_field <json> <field>: print a top-level string field, or empty.
json_string_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    raise SystemExit(0)
if not isinstance(payload, dict):
    raise SystemExit(0)
build = payload.get("build") if isinstance(payload.get("build"), dict) else payload
for source in (build, payload):
    value = source.get(sys.argv[2])
    if isinstance(value, str) and value:
        print(value)
        raise SystemExit(0)
PY
}

probe_local() {
    local binary_path installed_sha health_url reason expected_sha version detail
    binary_path="${FLAPJACK_PROBE_LOCAL_BINARY:-$(find_restart_ready_flapjack_binary 2>/dev/null || true)}"
    if [ -z "$binary_path" ] || [ ! -x "$binary_path" ]; then
        log "no selected local Flapjack binary found"
        emit_result "setup_infra" "missing_local_binary" "" "" "" "no selected local Flapjack binary"
    fi
    installed_sha="$(flapjack_binary_sha256 "$binary_path")"

    # Expected identity: honor a caller-provided Stage 1 manifest/env contract,
    # otherwise derive it from the selected binary's own source provenance.
    if ! expected_identity_present; then
        flapjack_export_required_runtime_identity "$binary_path" || true
    fi
    if ! expected_identity_present; then
        log "no Stage 1 expected identity for the selected local binary"
        emit_result "setup_infra" "missing_expected_identity" "$installed_sha" "" "" "no expected identity"
    fi
    expected_sha="${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}"

    health_url="${FLAPJACK_URL:-http://127.0.0.1:${FLAPJACK_LOCAL_PORT:-3200}}"
    reason="$(flapjack_runtime_identity_reason "$health_url")"
    version="${FJCLOUD_FLAPJACK_VERSION:-}"
    detail="local runtime reason=$reason"
    local classification
    classification="$(classify_evidence "$reason" "$installed_sha" "$expected_sha" "")"
    emit_result "$classification" "$reason" "$installed_sha" "$expected_sha" "$version" "$detail"
}

probe_remote() {
    local ssm_exec evidence installed_sha build_info health reason expected_sha version detail build_info_sha
    ssm_exec="${FLAPJACK_PROBE_SSM_EXEC:-$SCRIPT_DIR/launch/ssm_exec_staging.sh}"
    if [ ! -x "$ssm_exec" ]; then
        log "SSM exec wrapper not executable: not logging path"
        emit_result "setup_infra" "missing_ssm_exec" "" "" "" "ssm exec wrapper unavailable"
    fi

    if ! expected_identity_present; then
        log "no Stage 1 expected identity (manifest/env) for remote comparison"
        emit_result "setup_infra" "missing_expected_identity" "" "" "" "no expected identity"
    fi
    expected_sha="${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}"

    # Read-only host evidence: installed byte digest, binary self-report, service
    # health. Never prints secrets. The command is intentionally a single string.
    local remote_cmd='printf "sha256=%s\n" "$(sha256sum /usr/local/bin/flapjack 2>/dev/null | awk "{print \$1}")"; printf "build_info=%s\n" "$(/usr/local/bin/flapjack build-info --json 2>/dev/null | tr -d "\n")"; printf "health=%s\n" "$(curl -fsS -m 10 http://127.0.0.1:3200/health 2>/dev/null | tr -d "\n")"'
    if ! evidence="$(SSM_EXEC_ENVIRONMENT="$PROBE_ENV" "$ssm_exec" "$remote_cmd" 2>/dev/null)"; then
        log "SSM exec failed for env=$PROBE_ENV"
        emit_result "setup_infra" "ssm_unreachable" "" "$expected_sha" "" "SSM exec failed"
    fi

    installed_sha="$(printf '%s\n' "$evidence" | sed -n 's/^sha256=//p' | head -n1)"
    build_info="$(printf '%s\n' "$evidence" | sed -n 's/^build_info=//p' | head -n1)"
    health="$(printf '%s\n' "$evidence" | sed -n 's/^health=//p' | head -n1)"
    if [ -z "$installed_sha" ]; then
        log "SSM evidence missing installed binary sha256"
        emit_result "investigate" "missing_installed_sha" "" "$expected_sha" "" "no installed sha in host evidence"
    fi

    reason="$(flapjack_classify_health_json "$health")"
    build_info_sha="$(json_string_field "$build_info" "binary_sha256")"
    [ -n "$build_info_sha" ] || build_info_sha="$(json_string_field "$build_info" "sha256")"
    version="$(json_string_field "$health" "version")"
    detail="remote runtime reason=$reason"
    local classification
    classification="$(classify_evidence "$reason" "$installed_sha" "$expected_sha" "$build_info_sha")"
    emit_result "$classification" "$reason" "$installed_sha" "$expected_sha" "$version" "$detail"
}

case "$PROBE_ENV" in
    local) probe_local ;;
    staging|prod) probe_remote ;;
esac
