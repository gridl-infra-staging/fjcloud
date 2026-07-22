#!/usr/bin/env bash
# Shared Flapjack binary discovery helpers for local/integration/chaos scripts.
#
# Callers must define REPO_ROOT before sourcing this file.
#
# Contract:
# - Candidate repository order is fixed and bounded.
# - Directory candidates come from FLAPJACK_DEV_DIR (explicit), then
#   FLAPJACK_DEV_DIR_CANDIDATES (if set), then default repo-relative candidates.
# - Binary preference is fixed:
#   target/debug/flapjack
#   target/debug/flapjack-http
#   target/release/flapjack
#   target/release/flapjack-http
# - Restart-critical callers may fall back to PATH (`flapjack`, then
#   `flapjack-http`) only after directory candidates fail.

# Canonical fjcloud engine dependency. Runtime checks and CI artifact
# acquisition consume this value instead of carrying version literals.
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_BUILD_PACKAGE="flapjack-server"
FJCLOUD_FLAPJACK_LEGACY_RELEASE_SHA256="a3af301593a3dfddd2925011a46bc7d561c5ce607692733cae6740e04949207a"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2

default_flapjack_dev_dir_candidates() {
    printf '%s\n' \
        "$REPO_ROOT/../flapjack_dev" \
        "$REPO_ROOT/../flapjack_dev/engine" \
        "$REPO_ROOT/../../gridl-dev/flapjack_dev/engine" \
        "$REPO_ROOT/../../gridl-dev/flapjack_dev" \
        "${HOME:-}/repos/gridl-dev/flapjack_dev/engine" \
        "${HOME:-}/repos/gridl-dev/flapjack_dev" \
        "${HOME:-}/repos/flapjack_dev/engine" \
        "${HOME:-}/repos/flapjack_dev"
}

configured_flapjack_dev_dir_candidates() {
    if [ -n "${FLAPJACK_DEV_DIR:-}" ]; then
        printf '%s\n' "$FLAPJACK_DEV_DIR"
    fi

    local candidate
    if [ -n "${FLAPJACK_DEV_DIR_CANDIDATES:-}" ]; then
        for candidate in $FLAPJACK_DEV_DIR_CANDIDATES; do
            printf '%s\n' "$candidate"
        done
        return 0
    fi

    default_flapjack_dev_dir_candidates
}

resolve_default_flapjack_dev_dir() {
    if [ -n "${FLAPJACK_DEV_DIR:-}" ]; then
        printf '%s\n' "$FLAPJACK_DEV_DIR"
        return 0
    fi

    local candidate
    while IFS= read -r candidate; do
        [ -d "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(configured_flapjack_dev_dir_candidates)

    # Preserve the historical adjacent-checkout fallback for warning/error text.
    printf '%s\n' "$REPO_ROOT/../flapjack_dev"
}

find_flapjack_binary() {
    local flapjack_dev_dir="${1:-${FLAPJACK_DEV_DIR:-}}"
    [ -d "$flapjack_dev_dir" ] || return 1

    local source_root
    source_root="$(flapjack_source_root "$flapjack_dev_dir" || true)"
    if [ -n "$source_root" ]; then
        if resolve_source_backed_flapjack_binary "$source_root"; then
            return 0
        fi
        return "$FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS"
    fi

    local root candidate relative_path
    for relative_path in \
        "target/debug/flapjack" \
        "target/debug/flapjack-http" \
        "target/release/flapjack" \
        "target/release/flapjack-http"
    do
        for root in "$flapjack_dev_dir" "$flapjack_dev_dir/engine"; do
            candidate="$root/$relative_path"
            [ -x "$candidate" ] || continue
            printf '%s\n' "$candidate"
            return 0
        done
    done

    return 1
}

flapjack_binary_sha256() {
    local binary_path="$1"
    shasum -a 256 "$binary_path" | awk '{print $1}'
}

flapjack_binary_identity_reason() {
    local binary_path="$1" manifest_path="$2"
    [ -x "$binary_path" ] || {
        printf 'missing_binary\n'
        return 0
    }
    [ -f "$manifest_path" ] || {
        printf 'manifest_malformed\n'
        return 0
    }

    local actual_sha provenance
    actual_sha="$(flapjack_binary_sha256 "$binary_path")"
    provenance="$(flapjack_source_provenance_summary)"
    python3 - "$manifest_path" "$actual_sha" "$provenance" <<'PY'
import json
import re
import sys

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        print("manifest_malformed")
        raise SystemExit(0)

def manifest_build(payload):
    if isinstance(payload.get("build"), dict):
        return payload["build"]
    return payload

def first_string(payload, *names):
    for name in names:
        value = payload.get(name)
        if isinstance(value, str) and value:
            return value
    return ""

def first_bool(payload, *names):
    for name in names:
        value = payload.get(name)
        if isinstance(value, bool):
            return value
    return None

def token_after(provenance, token):
    parts = provenance.split(":")
    for index, part in enumerate(parts[:-1]):
        if part == token:
            return parts[index + 1]
    return ""

def source_receipt_path(provenance):
    match = re.search(r"(?:source-build|source-receipt):([^:]+)", provenance)
    if not match:
        return None
    return match.group(1)

def source_receipt_value(receipt_path, key):
    if not receipt_path:
        return ""
    try:
        with open(receipt_path, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(f"{key}="):
                    return line.strip().split("=", 1)[1]
    except OSError:
        return ""
    return ""

def source_receipt_first_value(receipt_path, *keys):
    for key in keys:
        value = source_receipt_value(receipt_path, key)
        if value:
            return value
    return ""

manifest = read_json(sys.argv[1])
payload = manifest_build(manifest)
actual_sha = sys.argv[2]
provenance = sys.argv[3]
receipt_path = source_receipt_path(provenance)
expected_sha = first_string(payload, "binary_sha256", "sha256")
artifact = payload.get("artifact")
if not isinstance(artifact, dict):
    artifact = manifest.get("artifact")
if not expected_sha and isinstance(artifact, dict):
    expected_sha = first_string(artifact, "sha256")
if expected_sha and expected_sha != actual_sha:
    print("checksum_mismatch")
    raise SystemExit(0)
expected_dirty = first_bool(payload, "dirty")
actual_dirty = None
if token_after(provenance, "dirty"):
    actual_dirty = token_after(provenance, "dirty") == "dirty"
if actual_dirty is None:
    receipt_dirty = source_receipt_value(receipt_path, "dirty")
    if receipt_dirty:
        actual_dirty = receipt_dirty == "dirty"
if expected_dirty is False and actual_dirty is True:
    print("dirty_local_build")
    raise SystemExit(0)
expected_revision = first_string(payload, "producer_revision", "revision")
actual_revision = token_after(provenance, "revision") or source_receipt_first_value(
    receipt_path,
    "git_revision",
    "revision",
)
if expected_revision and actual_revision and expected_revision != actual_revision:
    print("revision_mismatch")
    raise SystemExit(0)
expected_build_id = first_string(payload, "build_id", "workspaceDigest")
actual_build_id = (
    token_after(provenance, "build_id")
    or token_after(provenance, "workspaceDigest")
    or source_receipt_first_value(
        receipt_path,
        "build_id",
        "workspaceDigest",
        "source_digest",
    )
)
if expected_build_id and actual_build_id and expected_build_id != actual_build_id:
    print("build_id_mismatch")
    raise SystemExit(0)
print("match")
PY
}

flapjack_source_root() {
    local candidate_dir="$1"
    if [ -f "$candidate_dir/engine/Cargo.toml" ] && grep -q "$FJCLOUD_FLAPJACK_BUILD_PACKAGE" "$candidate_dir/engine/Cargo.toml"; then
        printf '%s\n' "$candidate_dir/engine"
        return 0
    fi
    if [ -f "$candidate_dir/Cargo.toml" ] && grep -q "$FJCLOUD_FLAPJACK_BUILD_PACKAGE" "$candidate_dir/Cargo.toml"; then
        printf '%s\n' "$candidate_dir"
        return 0
    fi
    return 1
}

flapjack_source_receipt_dir() {
    printf '%s\n' "${FLAPJACK_SOURCE_RECEIPT_DIR:-$REPO_ROOT/.local/flapjack-source-receipts}"
}

flapjack_provenance_file() {
    printf '%s\n' "${FLAPJACK_BINARY_PROVENANCE_FILE:-$(flapjack_source_receipt_dir)/last-provenance.$$}"
}

set_flapjack_binary_provenance() {
    local provenance="$1" provenance_file
    FLAPJACK_BINARY_PROVENANCE="$provenance"
    provenance_file="$(flapjack_provenance_file)"
    mkdir -p "$(dirname "$provenance_file")"
    printf '%s\n' "$provenance" > "$provenance_file"
}

flapjack_receipt_path_for_source() {
    local source_root="$1" receipt_dir receipt_key
    receipt_dir="$(flapjack_source_receipt_dir)"
    receipt_key="$(printf '%s' "$source_root" | shasum -a 256 | awk '{print $1}')"
    printf '%s/%s.receipt\n' "$receipt_dir" "$receipt_key"
}

flapjack_source_lock_path_for_receipt() {
    local receipt_path="$1"
    printf '%s.lock\n' "$receipt_path"
}

acquire_flapjack_source_lock() {
    local lock_path="$1"
    local timeout_seconds="${FLAPJACK_SOURCE_LOCK_TIMEOUT_SECONDS:-120}"
    local start_epoch now_epoch
    start_epoch="$(date +%s)"
    while ! mkdir "$lock_path" 2>/dev/null; do
        now_epoch="$(date +%s)"
        if [ $((now_epoch - start_epoch)) -ge "$timeout_seconds" ]; then
            printf 'Timed out waiting for Flapjack source build lock: %s\n' "$lock_path" >&2
            return 1
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$lock_path/pid"
}

release_flapjack_source_lock() {
    local lock_path="$1"
    [ -n "$lock_path" ] || return 0
    rm -rf "$lock_path"
}

flapjack_source_dirty_bit() {
    local source_root="$1"
    if git -C "$source_root" status --porcelain=v1 --untracked-files=all 2>/dev/null | grep -q .; then
        printf 'dirty\n'
    else
        printf 'clean\n'
    fi
}

flapjack_source_digest() {
    local source_root="$1"
    (
        cd "$source_root"
        git rev-parse HEAD 2>/dev/null || printf 'nogit\n'
        git status --porcelain=v1 --untracked-files=all 2>/dev/null || true
        git diff --binary HEAD 2>/dev/null || true
        while IFS= read -r -d '' source_file; do
            [ -f "$source_file" ] || continue
            flapjack_binary_sha256 "$source_file"
            printf '  %s\n' "$source_file"
        done < <(git ls-files -co --exclude-standard -z 2>/dev/null || true)
    ) | shasum -a 256 | awk '{print $1}'
}

flapjack_receipt_value() {
    local receipt_path="$1" key="$2"
    [ -f "$receipt_path" ] || return 1
    grep -E "^${key}=" "$receipt_path" | head -n 1 | cut -d= -f2-
}

flapjack_binary_workspace_digest() {
    local binary_path="$1"
    local build_info
    build_info="$("$binary_path" build-info --json 2>/dev/null)" || return 1
    python3 - "$build_info" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

build = payload.get("build") if isinstance(payload.get("build"), dict) else payload
if not isinstance(build, dict):
    raise SystemExit(1)

workspace_digest = build.get("workspaceDigest") or build.get("build_id")
if not isinstance(workspace_digest, str) or not workspace_digest:
    raise SystemExit(1)

print(workspace_digest)
PY
}

flapjack_provenance_token_after() {
    local provenance="$1" token="$2"
    python3 - "$provenance" "$token" <<'PY'
import sys

parts = sys.argv[1].split(":")
token = sys.argv[2]
for index, part in enumerate(parts[:-1]):
    if part == token:
        print(parts[index + 1])
        raise SystemExit(0)
raise SystemExit(1)
PY
}

flapjack_receipt_path_from_provenance() {
    local provenance="$1"
    case "$provenance" in
        source-build:*|source-receipt:*)
            printf '%s\n' "$(printf '%s' "$provenance" | cut -d: -f2)"
            ;;
        *)
            return 1
            ;;
    esac
}

flapjack_export_required_runtime_identity() {
    local binary_path="$1"
    [ -x "$binary_path" ] || return 1

    local provenance receipt_path revision build_id binary_sha
    provenance="$(flapjack_source_provenance_summary)"
    binary_sha="$(flapjack_binary_sha256 "$binary_path")"
    revision="$(flapjack_provenance_token_after "$provenance" "revision" || true)"
    build_id="$(flapjack_provenance_token_after "$provenance" "build_id" || true)"
    if [ -z "$build_id" ]; then
        build_id="$(flapjack_provenance_token_after "$provenance" "workspaceDigest" || true)"
    fi

    if receipt_path="$(flapjack_receipt_path_from_provenance "$provenance" 2>/dev/null)"; then
        [ -n "$revision" ] || revision="$(flapjack_receipt_value "$receipt_path" "git_revision" || true)"
        [ -n "$revision" ] || revision="$(flapjack_receipt_value "$receipt_path" "revision" || true)"
        [ -n "$build_id" ] || build_id="$(flapjack_receipt_value "$receipt_path" "build_id" || true)"
        [ -n "$build_id" ] || build_id="$(flapjack_receipt_value "$receipt_path" "workspaceDigest" || true)"
        [ -n "$build_id" ] || build_id="$(flapjack_receipt_value "$receipt_path" "source_digest" || true)"
    fi

    export FJCLOUD_FLAPJACK_REQUIRED_SHA256="$binary_sha"
    if [ -n "$revision" ]; then
        export FJCLOUD_FLAPJACK_REQUIRED_REVISION="$revision"
    fi
    if [ -n "$build_id" ]; then
        export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="$build_id"
    fi
}

flapjack_source_receipt_is_current() {
    local source_root="$1" source_digest="$2" dirty_bit="$3"
    local receipt_path binary_path
    receipt_path="$(flapjack_receipt_path_for_source "$source_root")"
    binary_path="$source_root/target/debug/flapjack"
    [ -x "$binary_path" ] || return 1
    [ -f "$receipt_path" ] || return 1

    local expected_binary_sha actual_binary_sha expected_build_id actual_build_id
    expected_binary_sha="$(flapjack_receipt_value "$receipt_path" "binary_sha256" || true)"
    actual_binary_sha="$(flapjack_binary_sha256 "$binary_path")"
    expected_build_id="$(flapjack_receipt_value "$receipt_path" "workspaceDigest" || true)"
    [ -n "$expected_build_id" ] || expected_build_id="$(flapjack_receipt_value "$receipt_path" "build_id" || true)"
    actual_build_id="$(flapjack_binary_workspace_digest "$binary_path" || true)"

    [ "$(flapjack_receipt_value "$receipt_path" "checkout_path" || true)" = "$source_root" ] || return 1
    [ "$(flapjack_receipt_value "$receipt_path" "source_digest" || true)" = "$source_digest" ] || return 1
    [ "$(flapjack_receipt_value "$receipt_path" "dirty" || true)" = "$dirty_bit" ] || return 1
    [ "$(flapjack_receipt_value "$receipt_path" "cargo_package" || true)" = "$FJCLOUD_FLAPJACK_BUILD_PACKAGE" ] || return 1
    [ -n "$expected_binary_sha" ] || return 1
    [ "$expected_binary_sha" = "$actual_binary_sha" ] || return 1
    [ -n "$expected_build_id" ] || return 1
    [ "$expected_build_id" = "$actual_build_id" ] || return 1
}

write_flapjack_source_receipt() {
    local source_root="$1" source_digest="$2" dirty_bit="$3" build_log="$4"
    local receipt_path receipt_dir receipt_tmp binary_path binary_sha built_at target_triple git_revision workspace_digest
    receipt_path="$(flapjack_receipt_path_for_source "$source_root")"
    receipt_dir="$(dirname "$receipt_path")"
    binary_path="$source_root/target/debug/flapjack"
    binary_sha="$(flapjack_binary_sha256 "$binary_path")"
    workspace_digest="$(flapjack_binary_workspace_digest "$binary_path")" || {
        printf 'Flapjack binary did not report build-info workspaceDigest: %s\n' "$binary_path" >&2
        return 1
    }
    built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    target_triple="$(rustc -vV 2>/dev/null | awk -F': ' '/^host:/ {print $2; exit}')"
    git_revision="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
    mkdir -p "$receipt_dir"
    receipt_tmp="$(mktemp "$receipt_dir/.flapjack-source-receipt.XXXXXX")"
    {
        printf 'checkout_path=%s\n' "$source_root"
        printf 'git_revision=%s\n' "$git_revision"
        printf 'source_digest=%s\n' "$source_digest"
        printf 'workspaceDigest=%s\n' "$workspace_digest"
        printf 'build_id=%s\n' "$workspace_digest"
        printf 'dirty=%s\n' "$dirty_bit"
        printf 'cargo_package=%s\n' "$FJCLOUD_FLAPJACK_BUILD_PACKAGE"
        printf 'cargo_profile=debug\n'
        printf 'cargo_features=default\n'
        printf 'target=%s\n' "${target_triple:-unknown}"
        printf 'binary_path=%s\n' "$binary_path"
        printf 'binary_sha256=%s\n' "$binary_sha"
        printf 'build_log=%s\n' "$build_log"
        printf 'built_at=%s\n' "$built_at"
    } > "$receipt_tmp"
    mv "$receipt_tmp" "$receipt_path"
}

build_flapjack_from_source() {
    local source_root="$1" build_log="$2"
    command -v cargo >/dev/null 2>&1 || {
        printf 'cargo not found for source-backed Flapjack build\n' >&2
        return 1
    }
    (cd "$source_root" && cargo build -p "$FJCLOUD_FLAPJACK_BUILD_PACKAGE" >"$build_log" 2>&1)
}

resolve_source_backed_flapjack_binary() {
    local source_root="$1"
    local binary_path="$source_root/target/debug/flapjack"
    local receipt_path lock_path source_digest dirty_bit build_log
    receipt_path="$(flapjack_receipt_path_for_source "$source_root")"
    lock_path="$(flapjack_source_lock_path_for_receipt "$receipt_path")"

    mkdir -p "$(flapjack_source_receipt_dir)"
    if ! acquire_flapjack_source_lock "$lock_path"; then
        return 1
    fi

    source_digest="$(flapjack_source_digest "$source_root")"
    dirty_bit="$(flapjack_source_dirty_bit "$source_root")"

    if flapjack_source_receipt_is_current "$source_root" "$source_digest" "$dirty_bit"; then
        set_flapjack_binary_provenance "source-receipt:$receipt_path"
        printf '%s\n' "$binary_path"
        release_flapjack_source_lock "$lock_path"
        return 0
    fi

    build_log="$(mktemp "$(flapjack_source_receipt_dir)/flapjack-build.XXXXXX")"
    if ! build_flapjack_from_source "$source_root" "$build_log"; then
        printf 'Flapjack source build failed; log: %s\n' "$build_log" >&2
        release_flapjack_source_lock "$lock_path"
        return 1
    fi
    [ -x "$binary_path" ] || {
        printf 'Flapjack source build did not produce executable %s; log: %s\n' "$binary_path" "$build_log" >&2
        release_flapjack_source_lock "$lock_path"
        return 1
    }
    if ! write_flapjack_source_receipt "$source_root" "$source_digest" "$dirty_bit" "$build_log"; then
        release_flapjack_source_lock "$lock_path"
        return 1
    fi
    set_flapjack_binary_provenance "source-build:$receipt_path"
    printf '%s\n' "$binary_path"
    release_flapjack_source_lock "$lock_path"
}

flapjack_release_artifact_is_allowed() {
    local binary_path="$1"
    [ -x "$binary_path" ] || return 1
    [ "$(flapjack_binary_sha256 "$binary_path")" = "$FJCLOUD_FLAPJACK_LEGACY_RELEASE_SHA256" ]
}

flapjack_source_provenance_summary() {
    local provenance_file
    if [ -n "${FLAPJACK_BINARY_PROVENANCE:-}" ]; then
        printf '%s\n' "$FLAPJACK_BINARY_PROVENANCE"
        return
    fi
    provenance_file="$(flapjack_provenance_file)"
    if [ -f "$provenance_file" ]; then
        cat "$provenance_file"
        return
    fi
    printf 'unknown\n'
}

find_restart_ready_flapjack_binary() {
    local flapjack_dev_dir="${1:-${FLAPJACK_DEV_DIR:-}}"
    local resolved_binary=""

    if [ -n "$flapjack_dev_dir" ]; then
        # A selected source checkout is authoritative. If its receipt validation
        # or build fails, substituting another checkout or PATH artifact would
        # run code other than the source the caller explicitly selected.
        if flapjack_source_root "$flapjack_dev_dir" >/dev/null 2>&1; then
            find_flapjack_binary "$flapjack_dev_dir"
            return $?
        fi

        resolved_binary="$(find_flapjack_binary "$flapjack_dev_dir" || true)"
        if [ -n "$resolved_binary" ] && [ -x "$resolved_binary" ]; then
            printf '%s\n' "$resolved_binary"
            return 0
        fi
    fi

    local candidate_dir
    while IFS= read -r candidate_dir; do
        [ -n "$candidate_dir" ] || continue
        [ "$candidate_dir" = "$flapjack_dev_dir" ] && continue
        resolved_binary="$(find_flapjack_binary "$candidate_dir" || true)"
        if [ -n "$resolved_binary" ] && [ -x "$resolved_binary" ]; then
            printf '%s\n' "$resolved_binary"
            return 0
        fi
    done < <(configured_flapjack_dev_dir_candidates)

    if [ -n "$resolved_binary" ] && [ -x "$resolved_binary" ]; then
        printf '%s\n' "$resolved_binary"
        return 0
    fi

    if command -v flapjack >/dev/null 2>&1; then
        resolved_binary="$(command -v flapjack)"
        if flapjack_release_artifact_is_allowed "$resolved_binary"; then
            set_flapjack_binary_provenance "legacy-release:${resolved_binary}:sha256:${FJCLOUD_FLAPJACK_LEGACY_RELEASE_SHA256}"
            printf '%s\n' "$resolved_binary"
            return 0
        fi
        printf 'Rejected unmanifested Flapjack release artifact: %s\n' "$resolved_binary" >&2
        return 1
    fi
    if command -v flapjack-http >/dev/null 2>&1; then
        resolved_binary="$(command -v flapjack-http)"
        if flapjack_release_artifact_is_allowed "$resolved_binary"; then
            set_flapjack_binary_provenance "legacy-release:${resolved_binary}:sha256:${FJCLOUD_FLAPJACK_LEGACY_RELEASE_SHA256}"
            printf '%s\n' "$resolved_binary"
            return 0
        fi
        printf 'Rejected unmanifested Flapjack release artifact: %s\n' "$resolved_binary" >&2
        return 1
    fi

    return 1
}
