#!/usr/bin/env bash
# e2e_deployed_pages_parity_probe_test.sh — contract harness for the
# e2e-deployed `Wait for staging Pages deploy parity` owner script.
#
# Stage 3 contract:
#   * source     = served bytes at PAGES_ALIAS_URL/_app/version.json
#   * owner      = scripts/launch/wait_for_pages_parity.sh
#   * field      = SvelteKit version JSON `version`
#   * comparison = exact match against TARGET_SHA
#
# The poll logic lives in scripts/launch/wait_for_pages_parity.sh so
# both the workflow step and these tests exercise a single owner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POLL_SCRIPT="$REPO_ROOT/scripts/launch/wait_for_pages_parity.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if [[ ! -f "$POLL_SCRIPT" ]]; then
    fail "owner script not found: $POLL_SCRIPT"
    echo ""
    echo "=== Results: 0 passed, 1 failed ==="
    exit 1
fi

# Build a sandbox PATH with a curl shim that serves deterministic Cloudflare
# API responses and served _app/version.json bytes from files under
# /tmp/<sandbox>.
make_sandbox() {
    local sb
    sb="$(mktemp -d)"
    mkdir -p "$sb/bin"
    cat >"$sb/bin/curl" <<'CURL_SHIM'
#!/usr/bin/env bash
set -euo pipefail
out=""
write_code=false
url=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -o)
            out="$2"
            shift 2
            ;;
        -w)
            write_code=true
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

body=""
code="200"
case "$url" in
    */_app/version.json)
        if [[ -f "$SANDBOX/version.json" ]]; then
            body="$(cat "$SANDBOX/version.json")"
        else
            code="404"
            body='{"error":"missing version fixture"}'
        fi
        ;;
    */client/v4/accounts)
        body='{"result":[{"id":"acct_test"}]}'
        ;;
    */client/v4/accounts/acct_test/pages/projects)
        body='{"result":[{"name":"flapjack-cloud"}]}'
        ;;
    */client/v4/accounts/acct_test/pages/projects/flapjack-cloud)
        body="$(cat "$SANDBOX/project_detail.json")"
        ;;
    *)
        code="404"
        body='{"success":false}'
        ;;
esac

if [[ -n "$out" ]]; then
    printf '%s' "$body" >"$out"
else
    printf '%s' "$body"
fi
if [[ "$write_code" == "true" ]]; then
    printf '%s' "$code"
fi
CURL_SHIM
    chmod +x "$sb/bin/curl"
    echo "$sb"
}

cleanup_sandboxes=()
trap '
    for sb in "${cleanup_sandboxes[@]:-}"; do
        [[ -n "$sb" && -d "$sb" ]] && rm -rf "$sb"
    done
' EXIT

run_case() {
    local case_name="$1"
    local expected_target_sha="$2"
    local expected_ready="$3"
    local project_detail_file="$4"
    local run_dir="${5:-$REPO_ROOT}"
    local served_version="${6:-$expected_target_sha}"
    local expected_rc="${7:-0}"

    local sb
    sb="$(make_sandbox)"
    cleanup_sandboxes+=("$sb")
    cp "$project_detail_file" "$sb/project_detail.json"
    write_version_json "$sb/version.json" "$served_version"

    local outfile errfile rc
    outfile="$(mktemp)"; errfile="$(mktemp)"
    cleanup_sandboxes+=("$outfile" "$errfile")

    # Override PATH so our curl shim is first; export sandbox for the shim.
    set +e
    (
        cd "$run_dir"
        PATH="$sb/bin:$PATH" \
            SANDBOX="$sb" \
            TARGET_SHA="$expected_target_sha" \
            CLOUDFLARE_GLOBAL_API_KEY="test-key" \
            CLOUDFLARE_X_Auth_Email="operator@example.com" \
            POLL_INTERVAL_SECONDS=0 \
            MAX_POLL_ATTEMPTS=3 \
            GITHUB_OUTPUT="$sb/github_output" \
            bash "$POLL_SCRIPT" >"$outfile" 2>"$errfile"
    )
    rc=$?
    set -e

    if [[ "$rc" -ne "$expected_rc" ]]; then
        fail "[$case_name] poll script exited $rc (expected $expected_rc); stderr: $(cat "$errfile")"
        return
    fi

    if [[ ! -f "$sb/github_output" ]]; then
        fail "[$case_name] poll script did not write to \$GITHUB_OUTPUT"
        return
    fi

    if grep -F "ready=$expected_ready" "$sb/github_output" >/dev/null; then
        pass "[$case_name] GITHUB_OUTPUT contains ready=$expected_ready"
    else
        fail "[$case_name] GITHUB_OUTPUT missing 'ready=$expected_ready'; got: $(cat "$sb/github_output")"
    fi

    if [[ "$expected_ready" == "false" ]]; then
        if grep -i "did not reach\|stale\|served" "$errfile" >/dev/null; then
            pass "[$case_name] emitted stale-content diagnostic to stderr"
        else
            fail "[$case_name] expected stale-content diagnostic on stderr; stderr: $(cat "$errfile")"
        fi
    fi
}

write_version_json() {
    local path="$1"
    local version="$2"
    cat >"$path" <<EOF
{"version":"$version"}
EOF
}

write_project_detail() {
    local path="$1"
    local canonical_commit="$2"
    local latest_commit="$3"
    local canonical_aliases="$4"
    local latest_aliases="$5"
    cat >"$path" <<EOF
{
  "result": {
    "name": "flapjack-cloud",
    "latest_deployment": {
      "deployment_trigger": {"metadata": {"commit_hash": "$latest_commit"}},
      "aliases": [$latest_aliases]
    },
    "canonical_deployment": {
      "deployment_trigger": {"metadata": {"commit_hash": "$canonical_commit"}},
      "aliases": [$canonical_aliases]
    }
  }
}
EOF
}

run_missing_credentials_case() {
    local sb outfile errfile rc
    sb="$(make_sandbox)"
    cleanup_sandboxes+=("$sb")
    write_project_detail "$sb/project_detail.json" "$(git rev-parse HEAD)" "$(git rev-parse HEAD)" '"https://cloud.staging.flapjack.foo"' '""'
    write_version_json "$sb/version.json" "$(git rev-parse HEAD)"
    outfile="$(mktemp)"; errfile="$(mktemp)"
    cleanup_sandboxes+=("$outfile" "$errfile")

    set +e
    PATH="$sb/bin:$PATH" \
        SANDBOX="$sb" \
        TARGET_SHA="$(git rev-parse HEAD)" \
        CLOUDFLARE_GLOBAL_API_KEY="" \
        CLOUDFLARE_X_Auth_Email="" \
        POLL_INTERVAL_SECONDS=0 \
        MAX_POLL_ATTEMPTS=1 \
        GITHUB_OUTPUT="$sb/github_output" \
        bash "$POLL_SCRIPT" >"$outfile" 2>"$errfile"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        fail "[missing-credentials] poll script exited $rc (expected 0); stderr: $(cat "$errfile")"
        return
    fi
    if grep -F "ready=true" "$sb/github_output" >/dev/null && ! grep -F "CLOUDFLARE_GLOBAL_API_KEY and CLOUDFLARE_X_Auth_Email are required" "$errfile" >/dev/null; then
        pass "[missing-credentials] served version can satisfy readiness without Cloudflare auth"
    else
        fail "[missing-credentials] expected ready=true without auth skip warning; stderr: $(cat "$errfile"); output: $(cat "$sb/github_output")"
    fi
}

make_git_repo_for_ancestor_cases() {
    local repo
    repo="$(mktemp -d)"
    cleanup_sandboxes+=("$repo")

    (
        cd "$repo"
        git init -q
        git config user.email "test@example.com"
        git config user.name "Pages Parity Test"

        mkdir -p docs web/src
        printf 'base\n' > docs/readme.md
        printf 'base\n' > web/src/app.txt
        git add docs/readme.md web/src/app.txt
        git commit -q -m base

        printf 'api-only\n' > docs/api_only.md
        git add docs/api_only.md
        git commit -q -m api-only

        printf 'web-change\n' > web/src/app.txt
        git add web/src/app.txt
        git commit -q -m web-change
    )

    echo "$repo"
}

target_sha="$(git rev-parse HEAD)"
old_sha="$(printf '%040d' 1 | tr '0-9' 'b' )"
alias='"https://cloud.staging.flapjack.foo"'
other_alias='"https://staging.flapjack-cloud.pages.dev"'

ancestor_repo="$(make_git_repo_for_ancestor_cases)"
ancestor_base_sha="$(cd "$ancestor_repo" && git rev-parse HEAD~2)"
api_only_target_sha="$(cd "$ancestor_repo" && git rev-parse HEAD~1)"
web_change_target_sha="$(cd "$ancestor_repo" && git rev-parse HEAD)"

tmp_resp1="$(mktemp)"
write_project_detail "$tmp_resp1" "$target_sha" "$old_sha" "$alias" "$other_alias"
run_case "canonical-alias-exact-hit" "$target_sha" "true" "$tmp_resp1"
rm -f "$tmp_resp1"

tmp_resp2="$(mktemp)"
write_project_detail "$tmp_resp2" "$ancestor_base_sha" "$old_sha" "$alias" "$other_alias"
run_case "canonical-alias-api-only-ancestor-hit" "$api_only_target_sha" "true" "$tmp_resp2" "$ancestor_repo"
rm -f "$tmp_resp2"

tmp_resp3="$(mktemp)"
write_project_detail "$tmp_resp3" "$target_sha" "$old_sha" "$alias" "$other_alias"
run_case "latest-differs-canonical-satisfies" "$target_sha" "true" "$tmp_resp3"
rm -f "$tmp_resp3"

tmp_resp4="$(mktemp)"
write_project_detail "$tmp_resp4" "$old_sha" "$target_sha" "$alias" "$other_alias"
run_case "canonical-alias-timeout-skip" "$target_sha" "false" "$tmp_resp4" "$REPO_ROOT" "$old_sha" 1
rm -f "$tmp_resp4"

tmp_resp5="$(mktemp)"
write_project_detail "$tmp_resp5" "$target_sha" "$old_sha" "$alias" "$other_alias"
run_case "canonical-alias-descendant-skip" "$(git rev-parse HEAD~1)" "false" "$tmp_resp5" "$REPO_ROOT" "$target_sha" 1
rm -f "$tmp_resp5"

tmp_resp6="$(mktemp)"
write_project_detail "$tmp_resp6" "$ancestor_base_sha" "$old_sha" "$alias" "$other_alias"
run_case "canonical-alias-web-change-ancestor-skip" "$web_change_target_sha" "false" "$tmp_resp6" "$ancestor_repo" "$ancestor_base_sha" 1
rm -f "$tmp_resp6"

tmp_resp7="$(mktemp)"
write_project_detail "$tmp_resp7" "$target_sha" "$old_sha" "$alias" "$other_alias"
run_case "metadata-match-served-version-stale-fails" "$target_sha" "false" "$tmp_resp7" "$REPO_ROOT" "$old_sha" 1
rm -f "$tmp_resp7"

run_missing_credentials_case

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
