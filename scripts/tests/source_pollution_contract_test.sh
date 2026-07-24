#!/usr/bin/env bash
# Contract test: active source owners, DIRMAP, and the current Stage 1 evidence
# surfaces must not record session-specific workstation absolute paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

escape_ere() {
    printf '%s\n' "$1" | sed 's/[][(){}.^$*+?|\\/]/\\&/g'
}

join_patterns() {
    local pattern=""
    local candidate
    for candidate in "$@"; do
        if [ -z "$candidate" ] || [ "$candidate" = "/" ]; then
            continue
        fi
        if [ -z "$pattern" ]; then
            pattern="$candidate"
        else
            pattern="$pattern|$candidate"
        fi
    done
    printf '%s\n' "$pattern"
}

forbidden_absolute_path_pattern() {
    local generic_patterns=(
        '/Users/[[:alnum:]_.-]+/'
        '/home/[[:alnum:]_.-]+/'
        'file:///Users/[[:alnum:]_.-]+/'
        'file:///home/[[:alnum:]_.-]+/'
        '/private/var/folders/[[:alnum:]_.-]+/'
        'file:///private/var/folders/[[:alnum:]_.-]+/'
    )
    local host_patterns=()
    host_patterns+=("$(escape_ere "$REPO_ROOT")")
    if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ]; then
        host_patterns+=("$(escape_ere "$HOME")")
    fi

    join_patterns "${generic_patterns[@]}" "${host_patterns[@]}"
}

latest_invite_ready_bundle() {
    git -C "$REPO_ROOT" ls-files \
        | awk -F/ '/^docs\/runbooks\/evidence\/invite-ready-rc\// && NF >= 5 { print $5 }' \
        | sort -u \
        | tail -1
}

# The current `docs/live-state/<UTC>/` snapshot Stage 1 regenerates via
# `scripts/probe_live_state.sh`. Historical snapshots and `lane_evidence/`
# subtrees are intentionally excluded — they're archived artifacts with
# pre-existing workstation paths that this stage's guard is not chartered to
# rewrite.
latest_live_state_snapshot() {
    git -C "$REPO_ROOT" ls-files \
        | awk -F/ '/^docs\/live-state\// && NF >= 3 && $3 ~ /^[0-9]{8}T[0-9]{6}Z$/ { print $3 }' \
        | sort -u \
        | tail -1
}

tracked_scan_files() {
    local latest_bundle latest_live_state
    latest_bundle="$(latest_invite_ready_bundle)"
    latest_live_state="$(latest_live_state_snapshot)"

    git -C "$REPO_ROOT" ls-files \
        | grep -E '^(infra/|web/|DIRMAP\.md$|.+/DIRMAP\.md$|scripts/[^/]+\.sh$|scripts/.+\.py$|\.github/workflows/ci\.yml$|scripts/local-ci\.sh$|scripts/launch/invoke_rc_with_env\.sh$|scripts/launch/run_full_backend_validation\.sh$|scripts/lib/rc_invocation\.sh$)' \
        | grep -Ev '^scripts/tests/|^scripts/.*/test_.*\.py$' || true
    printf '%s\n' \
        '.github/workflows/ci.yml' \
        'scripts/local-ci.sh' \
        'scripts/launch/invoke_rc_with_env.sh' \
        'scripts/launch/run_full_backend_validation.sh' \
        'scripts/lib/rc_invocation.sh' \
        'scripts/tests/source_pollution_contract_test.sh'
    if [ -n "$latest_bundle" ]; then
        git -C "$REPO_ROOT" ls-files | grep -E "^docs/runbooks/evidence/invite-ready-rc/$latest_bundle/" || true
    fi
    if [ -n "$latest_live_state" ]; then
        git -C "$REPO_ROOT" ls-files | grep -E "^docs/live-state/$latest_live_state/" || true
    fi
}

filter_allowed_absolute_paths() {
    local canonical_secret_file_pattern
    canonical_secret_file_pattern="$(printf '/%s/%s/repos/gridl-infra-dev/fjcloud_dev/\\.secret/\\.env\\.secret' Users stuart)"
    grep -Ev "(/home/(deploy|ec2-user)/|$canonical_secret_file_pattern)" || true
}

echo "=== source pollution contract tests ==="

implementation_matches="$(
    grep -n 'Users/stuart/parallel_development' "$0" \
        | grep -v 'source pollution guard hard-codes one workstation path' \
        | grep -v "grep -n 'Users/stuart/parallel_development'" \
        || true
)"
if [ -n "$implementation_matches" ]; then
    fail "source pollution guard hard-codes one workstation path"
else
    pass "source pollution guard derives forbidden absolute paths at runtime"
fi

forbidden_pattern="$(forbidden_absolute_path_pattern)"
if [ -z "$forbidden_pattern" ]; then
    fail "source pollution guard could not derive forbidden absolute path prefixes"
else
    pass "source pollution guard has generic forbidden absolute path prefixes"
fi

generic_fixture="stack at file:///${USER_ROOT:-Users}/alice/src/fjcloud_dev/web/playwright.config.ts:10:2"
if printf '%s\n' "$generic_fixture" | grep -Eq "$forbidden_pattern"; then
    pass "source pollution guard catches non-current-host workstation paths"
else
    fail "source pollution guard misses generic non-current-host workstation paths"
fi

scan_file_list="$(tracked_scan_files | sort -u)"
scan_files=()
while IFS= read -r tracked_file; do
    [ -n "$tracked_file" ] || continue
    scan_files+=("$tracked_file")
done <<EOF
$scan_file_list
EOF

# Public mirrors track no docs/live-state/ snapshots (debbie whitelist excludes
# them), so the coverage assertion is vacuous there; it still bites in the dev
# repo, where a snapshot is always tracked.
if [ -z "$(latest_live_state_snapshot)" ]; then
    pass "source pollution guard live-state coverage skipped: no docs/live-state/<UTC>/ snapshot tracked (mirror context)"
elif grep -q "^docs/live-state/$(latest_live_state_snapshot)/" <<< "$scan_file_list"; then
    pass "source pollution guard covers the current docs/live-state/<UTC>/ snapshot"
else
    fail "source pollution guard does not cover the current docs/live-state/<UTC>/ snapshot"
fi

if grep -qxF 'scripts/seed_staging_dunning_test_tenant.sh' <<< "$scan_file_list"; then
    pass "source pollution guard covers root shell owners under scripts/"
else
    fail "source pollution guard does not cover root shell owners under scripts/"
fi

if grep -qxF 'scripts/w3_triage/emit_dispatch_manifest.py' <<< "$scan_file_list"; then
    pass "source pollution guard covers Python owners under scripts/"
else
    fail "source pollution guard does not cover Python owners under scripts/"
fi

matches="$(
    git -C "$REPO_ROOT" grep -nE \
        "$forbidden_pattern" \
        -- "${scan_files[@]}" 2>/dev/null \
        | filter_allowed_absolute_paths || true
)"

if [ -n "$matches" ]; then
    fail "active source owners, DIRMAP, latest invite-ready RC evidence, or current live-state snapshot contains workstation-absolute paths
$matches"
else
    pass "active source owners, DIRMAP, latest invite-ready RC evidence, and current live-state snapshot exclude workstation-absolute paths"
fi

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
