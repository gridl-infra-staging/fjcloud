#!/usr/bin/env bash
# ci_e2e_deployed_pages_parity_test.sh — Contract test: the e2e-deployed CI
# job must include a pre-poll step that waits for served staging Pages bytes
# to reach $GITHUB_SHA before running the browser bundle. Stale Pages content
# must fail loudly before browser evidence is trusted.
#
# Asserts on .github/workflows/ci.yml:
#   (a) e2e-deployed has a poll step with `id:` set,
#       a name containing "pages parity" or "deploy parity", delegates to the
#       single owner script, passes TARGET_SHA, does not skip-green via
#       `continue-on-error`, and does not require Cloudflare auth secrets for
#       readiness.
#   (b) The "Run deployed staging browser lane wrapper" step is not gated on
#       `steps.<poll_id>.outputs.ready`.
#   (c) The "Upload launch verification artifacts" step still has
#       `if: always()` — artifact upload must NOT be gated on parity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

job_block() {
    local job_name="$1"
    awk -v job="$job_name" '
        $0 ~ "^  " job ":$" { in_job=1; print; next }
        in_job && $0 ~ "^  [a-zA-Z0-9_-]+:$" { exit }
        in_job { print }
    ' "$WORKFLOW_FILE"
}

# Extract the step block whose `name:` line matches `name_regex`
# (case-insensitive substring). A step block starts at a "- " line at
# indent 6 (e.g. "      - name:" or "      - uses:") and ends just before
# the next such line.
step_block_by_name_regex() {
    local job_block_text="$1"
    local name_regex="$2"
    echo "$job_block_text" | awk -v re="$name_regex" '
        /^      - / {
            if (in_step && found) { print buf; exit }
            buf = $0 ORS
            in_step = 1
            found = 0
            if ($0 ~ "name:" && tolower($0) ~ tolower(re)) { found = 1 }
            next
        }
        in_step {
            buf = buf $0 ORS
            if ($0 ~ "name:" && tolower($0) ~ tolower(re)) { found = 1 }
        }
        END { if (in_step && found) print buf }
    '
}

test_pages_parity_poll_step_present() {
    local block
    block="$(job_block "e2e-deployed")"
    if [[ -z "$block" ]]; then
        fail "e2e-deployed job block not found in ci.yml"
        return
    fi

    local step
    step="$(step_block_by_name_regex "$block" "pages parity|deploy parity")"
    if [[ -z "$step" ]]; then
        fail "e2e-deployed missing a step whose name contains 'pages parity' or 'deploy parity'"
        return
    fi
    pass "e2e-deployed has a pages/deploy parity step"

    if echo "$step" | grep -E '^[[:space:]]+id:[[:space:]]+[A-Za-z0-9_]+' >/dev/null 2>&1; then
        pass "parity step declares an id:"
    else
        fail "parity step missing 'id:' (needed for steps.<id>.outputs.ready gating)"
    fi

    if echo "$step" | grep -E '^[[:space:]]+continue-on-error:[[:space:]]+true' >/dev/null 2>&1; then
        fail "parity step still has continue-on-error: true (stale served content must fail loudly)"
    else
        pass "parity step does not skip-green with continue-on-error: true"
    fi

    if echo "$step" | grep -E 'run:[[:space:]]+bash scripts/launch/wait_for_pages_parity\.sh' >/dev/null 2>&1; then
        pass "parity step delegates to scripts/launch/wait_for_pages_parity.sh"
    else
        fail "parity step must delegate to scripts/launch/wait_for_pages_parity.sh"
    fi

    if echo "$step" | grep -E 'TARGET_SHA:[[:space:]]+\$\{\{[[:space:]]*github\.sha[[:space:]]*\}\}' >/dev/null 2>&1; then
        pass "parity step passes TARGET_SHA from github.sha"
    else
        fail "parity step missing TARGET_SHA: \${{ github.sha }}"
    fi

    if echo "$step" | grep -E 'CLOUDFLARE_GLOBAL_API_KEY|CLOUDFLARE_X_Auth_Email' >/dev/null 2>&1; then
        fail "parity step still wires Cloudflare auth secrets for readiness"
    else
        pass "parity step does not require Cloudflare auth secrets for readiness"
    fi

    if echo "$step" | grep -E 'served|_app/version\.json' >/dev/null 2>&1; then
        pass "parity step comments document served-content authority"
    else
        fail "parity step comments should name served content or _app/version.json authority"
    fi
}

test_wrapper_step_not_gated_on_ready() {
    local block
    block="$(job_block "e2e-deployed")"
    [[ -z "$block" ]] && { fail "e2e-deployed job block not found"; return; }

    local step
    step="$(step_block_by_name_regex "$block" "Run deployed staging browser lane wrapper")"
    if [[ -z "$step" ]]; then
        fail "wrapper step 'Run deployed staging browser lane wrapper' not found"
        return
    fi

    if echo "$step" | grep -E "outputs\.ready|steps\.[A-Za-z0-9_]+\.outputs" >/dev/null 2>&1; then
        fail "wrapper step still uses parity ready output as a skip-green gate"
    else
        pass "wrapper step is not gated on parity ready output"
    fi
}

test_upload_step_unconditional() {
    local block
    block="$(job_block "e2e-deployed")"
    [[ -z "$block" ]] && { fail "e2e-deployed job block not found"; return; }

    local step
    step="$(step_block_by_name_regex "$block" "Upload launch verification artifacts")"
    if [[ -z "$step" ]]; then
        fail "upload step 'Upload launch verification artifacts' not found"
        return
    fi

    if echo "$step" | grep -E "if:[[:space:]]+always\(\)" >/dev/null 2>&1; then
        pass "upload step retains 'if: always()' (artifacts upload even on skip/fail)"
    else
        fail "upload step missing 'if: always()' — artifacts must upload regardless of parity outcome"
    fi

    if echo "$step" | grep -E "outputs\.ready" >/dev/null 2>&1; then
        fail "upload step references outputs.ready — it must NOT be gated on parity"
    else
        pass "upload step is not gated on parity ready output"
    fi
}

main() {
    echo "=== ci_e2e_deployed_pages_parity_test.sh ==="
    echo ""

    test_pages_parity_poll_step_present
    test_wrapper_step_not_gated_on_ready
    test_upload_step_unconditional

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
