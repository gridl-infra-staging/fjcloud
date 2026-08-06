#!/usr/bin/env bash
# Tests for scripts/devbox/sync_to_devbox.sh — pushes the working tree to the
# devbox without putting credentials on it.
#
# The load-bearing test is test_secret_dir_is_never_transferred. The devbox is
# deliberately launched with no IAM role so it holds no AWS credentials (see
# provision_devbox.sh); rsyncing `.secret/` would hand it the static IAM keys,
# the Stripe keys and the OAuth secrets in one step and undo that design
# entirely. ROADMAP.md still carries an OPEN P0 for credentials exposed through
# the public mirror, so this is a live concern, not a hypothetical one.
#
# These tests do NOT grep the script for "--exclude". A flag can be present and
# still not take effect — wrong position, wrong pattern anchoring, overridden by
# a later --include. Instead they run the real rsync in dry-run against a
# fixture tree and assert on what it actually reports it would transfer. That is
# the difference between testing the string and testing the behaviour.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

SYNC="$REPO_ROOT/scripts/devbox/sync_to_devbox.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Build a fixture tree shaped like the repo: a credential dir that must never
# move, two build-artifact dirs that must not move because they are enormous and
# platform-specific, and ordinary source that must move.
make_fixture_tree() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/src/hugedir" "$root/src/.secret" "$root/src/node_modules/pkg" \
             "$root/src/infra/target/debug" "$root/src/infra/api/tests" "$root/src/web/src" "$root/src/dest" \
             "$root/src/.mike/somelane/logs"
    echo "AWS_SECRET_ACCESS_KEY=must-never-leave-this-host" > "$root/src/.secret/.env.secret"
    echo "devbox-private-key" > "$root/src/.secret/fjcloud-devbox.pem"
    echo '{"log":"AKIATDTCEXAMPLEKEY01"}' > "$root/src/.mike/somelane/logs/run_1.json"
    echo "junk" > "$root/src/node_modules/pkg/index.js"
    echo "junk" > "$root/src/infra/target/debug/binary"
    echo "real source" > "$root/src/web/src/app.ts"
    echo "real source" > "$root/src/Makefile"
    echo "enormous" > "$root/src/hugedir/blob.bin"
    echo "AWS_ACCESS_KEY_ID=AKIALOCALENVEXAMPLE1" > "$root/src/.env.local"
    echo "generated regression fixture" > "$root/src/infra/api/tests/_local_ci_set_e_regression_fixture.generated.rs"
    echo "$root"
}

# Run the sync in dry-run against a LOCAL destination and return rsync's own
# report of what it would transfer. --dest takes any rsync destination, so no
# test-only branch exists in the script under test.
run_sync_dry() {
    local root="$1"; shift
    bash "$SYNC" --source "$root/src" --dest "$root/dest" --dry-run "$@" 2>&1
}

test_system_under_test_exists() {
    assert_file_exists "$SYNC" "the sync script exists"
}

test_secret_dir_is_never_transferred() {
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root")"
    assert_not_contains "$out" ".secret" \
        "rsync would not transfer the .secret directory"
    assert_not_contains "$out" "fjcloud-devbox.pem" \
        "rsync would not transfer the devbox private key"
    rm -rf "$root"
}

test_real_source_is_transferred() {
    # The mirror image of the exclusion test. Without it, a script that excluded
    # everything would pass the security tests while being completely useless —
    # the classic vacuous green.
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root")"
    assert_contains "$out" "app.ts" "rsync would transfer ordinary source files"
    assert_contains "$out" "Makefile" "rsync would transfer repo-root files"
    rm -rf "$root"
}

test_build_artifacts_are_not_transferred() {
    # Not a security property, a throughput one: these dirs are gigabytes and
    # the Mac's are the wrong architecture for the Linux box anyway.
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root")"
    assert_not_contains "$out" "node_modules" "rsync would not transfer node_modules"
    assert_not_contains "$out" "target/debug" "rsync would not transfer cargo build output"
    rm -rf "$root"
}

test_dry_run_writes_nothing() {
    local root
    root="$(make_fixture_tree)"
    run_sync_dry "$root" >/dev/null
    if [ -z "$(ls -A "$root/dest")" ]; then
        pass "--dry-run leaves the destination empty"
    else
        fail "--dry-run wrote into the destination"
    fi
    rm -rf "$root"
}

test_real_run_actually_copies_and_still_excludes_secrets() {
    # The exclusion must hold on a REAL transfer, not only in dry-run. A dry-run
    # only exclusion would be the worst possible outcome: green tests, leaked
    # credentials.
    local root
    root="$(make_fixture_tree)"
    bash "$SYNC" --source "$root/src" --dest "$root/dest" >/dev/null 2>&1
    if [ -f "$root/dest/web/src/app.ts" ]; then
        pass "a real run copies source across"
    else
        fail "a real run did not copy source across"
    fi
    if [ -e "$root/dest/.secret" ]; then
        fail "a real run LEAKED .secret to the destination"
    else
        pass "a real run does not copy .secret to the destination"
    fi
    rm -rf "$root"
}

test_requires_a_destination() {
    local rc=0 out
    out="$(bash "$SYNC" --source "$REPO_ROOT" 2>&1)" || rc=$?
    assert_ne "$rc" "0" "a missing --dest is refused"
    assert_contains "$out" "DEVBOX_REFUSED:" \
        "the refusal is an explicit diagnostic, not an incidental non-zero exit"
}

test_orchestration_scratch_is_not_transferred() {
    # Found by a real sync, not by inspection: .mike/ holds orchestration logs,
    # and one of them carried an AWS-shaped access key id. The box is designed to
    # hold no credential material, and these logs are not needed to run tests, so
    # the whole directory stays on the operator machine.
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root")"
    assert_not_contains "$out" ".mike" \
        "rsync would not transfer orchestration scratch"
    assert_not_contains "$out" "run_1.json" \
        "rsync would not transfer orchestration logs holding key-shaped strings"
    rm -rf "$root"
}

test_generated_env_local_is_not_transferred() {
    # .env.local is generated from the operator's secret file and can therefore
    # contain live infrastructure credentials. It is gitignored, so it never
    # reaches the mirror — but rsync does not consult .gitignore, and pushing it
    # would put exactly the credential set on the box that launching without an
    # IAM role was meant to avoid. The box generates its own from the template.
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root")"
    assert_not_contains "$out" ".env.local" \
        "rsync would not transfer the generated .env.local"
    rm -rf "$root"
}

test_devbox_generated_playwright_auth_state_is_not_deleted() {
    # Playwright's setup projects write storage state to web/tests/fixtures/.auth/
    # ON THE DEVBOX. That path is gitignored (web/.gitignore:26), so it is absent
    # from the source tree, and `rsync -a --delete` therefore deletes it from the
    # destination on every sync. When a second session synced during a run, the
    # live run lost its auth state mid-flight and scored 201-243 instead of 334,
    # failing on `ENOENT tests/fixtures/.auth/*.json` while all four setup
    # projects still reported passed — a mass failure that looks like a product
    # regression and is not one. rsync does not delete EXCLUDED paths under plain
    # --delete, so excluding it is what protects it.
    #
    # This asserts on rsync's own deletion report, not on the transfer list: the
    # defect is what --delete removes at the destination, which every other test
    # in this file is blind to.
    local root out
    root="$(make_fixture_tree)"
    mkdir -p "$root/dest/web/tests/fixtures/.auth"
    echo '{"cookies":[]}' > "$root/dest/web/tests/fixtures/.auth/user.json"
    # The dry run already itemises with -n -i, which reports removals as
    # `*deleting <path>`; no extra flag is needed to observe them.
    out="$(run_sync_dry "$root")"
    assert_not_contains "$out" "deleting web/tests/fixtures/.auth" \
        "a sync does not delete devbox-generated Playwright auth state"
    rm -rf "$root"
}

test_generated_set_e_fixture_is_not_transferred() {
    # An interrupted local_ci_gate_set_e_test.sh leaves this untracked Rust file
    # under infra/api/tests/. Shipping it to Linux makes cargo fail on the
    # generated filename before the real gate under investigation can run.
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root")"
    assert_not_contains "$out" "_local_ci_set_e_regression_fixture" \
        "rsync would not transfer generated set-e regression fixtures"
    rm -rf "$root"
}

test_extra_excludes_are_honoured() {
    # The engine repo needs the same push but carries a multi-gigabyte directory
    # that is not a cargo workspace member. A caller-supplied exclude keeps that
    # sync reproducible as a command rather than an ad-hoc one-off rsync.
    local root out
    root="$(make_fixture_tree)"
    out="$(run_sync_dry "$root" --exclude hugedir || true)"
    assert_not_contains "$out" "blob.bin" \
        "a caller-supplied --exclude keeps that path out of the transfer"
    # And it must not disable the built-in exclusions.
    assert_not_contains "$out" ".secret" \
        "a caller-supplied --exclude does not weaken the credential exclusion"
    assert_contains "$out" "app.ts" \
        "a caller-supplied --exclude does not stop ordinary source transferring"
    rm -rf "$root"
}

for t in \
    test_system_under_test_exists \
    test_secret_dir_is_never_transferred \
    test_real_source_is_transferred \
    test_build_artifacts_are_not_transferred \
    test_orchestration_scratch_is_not_transferred \
    test_generated_env_local_is_not_transferred \
    test_devbox_generated_playwright_auth_state_is_not_deleted \
    test_generated_set_e_fixture_is_not_transferred \
    test_extra_excludes_are_honoured \
    test_dry_run_writes_nothing \
    test_real_run_actually_copies_and_still_excludes_secrets \
    test_requires_a_destination \
    ; do
    "$t"
done

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
