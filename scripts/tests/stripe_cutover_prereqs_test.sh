#!/usr/bin/env bash
# Contract tests for scripts/stripe_cutover_prereqs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_PATH="$REPO_ROOT/scripts/stripe_cutover_prereqs.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

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

run_prereq_script() {
    local stdout_file="$1"
    local stderr_file="$2"
    shift 2

    local exit_code=0
    (
        cd "$REPO_ROOT"
        env "$@" bash "$SCRIPT_PATH" >"$stdout_file" 2>"$stderr_file"
    ) || exit_code=$?

    printf '%s\n' "$exit_code"
}

run_prereq_script_path() {
    local script_path="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    shift 3

    local exit_code=0
    (
        cd "$REPO_ROOT"
        env "$@" bash "$script_path" >"$stdout_file" 2>"$stderr_file"
    ) || exit_code=$?

    printf '%s\n' "$exit_code"
}

create_isolated_prereq_repo() {
    local tmp_dir="$1"
    local isolated_repo="$tmp_dir/repo"

    mkdir -p "$isolated_repo/scripts/lib" "$isolated_repo/docs/runbooks/evidence/secret-rotation"
    cp "$SCRIPT_PATH" "$isolated_repo/scripts/stripe_cutover_prereqs.sh"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$isolated_repo/scripts/lib/env.sh"
    chmod +x "$isolated_repo/scripts/stripe_cutover_prereqs.sh"
    printf '%s\n' "$isolated_repo"
}

write_complete_secret_file() {
    local path="$1"
    cat > "$path" <<'SECRET'
STRIPE_SECRET_KEY=sk_test_existing_broad_key
STRIPE_WEBHOOK_SECRET=whsec_existing
STRIPE_SECRET_KEY_RESTRICTED=rk_test_restricted_key
# STRIPE_RESTRICTED_KEY_ID=rk_stage1_restricted_id
# STRIPE_OLD_KEY_ID=rk_stage1_old_id
SECRET
}

assert_file_exists() {
    local path="$1"
    local message="$2"
    if [ -f "$path" ]; then
        pass "$message"
    else
        fail "$message (missing file: $path)"
    fi
}

count_cutover_bundles() {
    local evidence_root="$1/docs/runbooks/evidence/secret-rotation"
    local count=0
    local candidate
    shopt -s nullglob
    for candidate in "$evidence_root"/*_stripe_cutover; do
        [ -d "$candidate" ] || continue
        count=$((count + 1))
    done
    shopt -u nullglob
    printf '%s\n' "$count"
}

test_fails_when_restricted_key_missing_and_names_gap() {
    local tmp_dir secret_file evidence_dir stdout_file stderr_file exit_code action_doc
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    secret_file="$tmp_dir/prereq_missing.env.secret"
    evidence_dir="$tmp_dir/evidence"
    stdout_file="$tmp_dir/stdout.txt"
    stderr_file="$tmp_dir/stderr.txt"

    cat > "$secret_file" <<'SECRET'
STRIPE_SECRET_KEY=sk_test_existing_broad_key
STRIPE_WEBHOOK_SECRET=whsec_existing
# STRIPE_RESTRICTED_KEY_ID=rk_stage1_restricted_id
# STRIPE_OLD_KEY_ID=rk_stage1_old_id
SECRET

    exit_code="$(run_prereq_script "$stdout_file" "$stderr_file" \
        FJCLOUD_SECRET_FILE="$secret_file" \
        STRIPE_CUTOVER_EVIDENCE_DIR="$evidence_dir")"

    assert_eq "$exit_code" "1" "missing restricted key should fail"
    assert_contains "$(cat "$stderr_file")" "REASON: prerequisite_missing" \
        "missing restricted key should emit stable reason"

    action_doc="$evidence_dir/OPERATOR_ACTION_REQUIRED.md"
    assert_file_exists "$action_doc" "missing restricted key should write operator action doc"
    assert_contains "$(cat "$action_doc")" "STRIPE_SECRET_KEY_RESTRICTED" \
        "operator action doc should name missing restricted key"
}

test_enforces_comment_markers_from_raw_secret_file() {
    local tmp_dir secret_file evidence_dir stdout_file stderr_file exit_code action_doc
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    secret_file="$tmp_dir/missing_comment_marker.env.secret"
    evidence_dir="$tmp_dir/evidence"
    stdout_file="$tmp_dir/stdout.txt"
    stderr_file="$tmp_dir/stderr.txt"

    cat > "$secret_file" <<'SECRET'
STRIPE_SECRET_KEY=sk_test_existing_broad_key
STRIPE_WEBHOOK_SECRET=whsec_existing
STRIPE_SECRET_KEY_RESTRICTED=rk_test_restricted_key
# STRIPE_RESTRICTED_KEY_ID=rk_stage1_restricted_id
SECRET

    exit_code="$(run_prereq_script "$stdout_file" "$stderr_file" \
        FJCLOUD_SECRET_FILE="$secret_file" \
        STRIPE_CUTOVER_EVIDENCE_DIR="$evidence_dir")"

    assert_eq "$exit_code" "1" "missing old key comment marker should fail"
    assert_contains "$(cat "$stderr_file")" "REASON: prerequisite_missing" \
        "missing comment marker should emit stable reason"

    action_doc="$evidence_dir/OPERATOR_ACTION_REQUIRED.md"
    assert_file_exists "$action_doc" "missing comment marker should write operator action doc"
    assert_contains "$(cat "$action_doc")" "STRIPE_OLD_KEY_ID" \
        "operator action doc should name missing comment marker"
}

test_honors_secret_file_override_and_evidence_dir_override() {
    local tmp_dir isolated_repo script_path default_secret_dir default_secret_file override_secret_file evidence_dir stdout_file stderr_file exit_code status_doc
    local before_default_bundle_count after_default_bundle_count
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    isolated_repo="$(create_isolated_prereq_repo "$tmp_dir")"
    script_path="$isolated_repo/scripts/stripe_cutover_prereqs.sh"
    default_secret_dir="$isolated_repo/.secret"
    default_secret_file="$default_secret_dir/.env.secret"
    override_secret_file="$tmp_dir/override.env.secret"
    evidence_dir="$tmp_dir/evidence"
    stdout_file="$tmp_dir/stdout.txt"
    stderr_file="$tmp_dir/stderr.txt"
    mkdir -p "$default_secret_dir"

    before_default_bundle_count="$(count_cutover_bundles "$isolated_repo")"

    cat > "$default_secret_file" <<'SECRET'
STRIPE_SECRET_KEY=sk_test_existing_broad_key
STRIPE_WEBHOOK_SECRET=whsec_existing
# intentionally missing STRIPE_SECRET_KEY_RESTRICTED to prove override wins
SECRET

    write_complete_secret_file "$override_secret_file"

    exit_code="$(run_prereq_script_path "$script_path" "$stdout_file" "$stderr_file" \
        FJCLOUD_SECRET_FILE="$override_secret_file" \
        STRIPE_CUTOVER_EVIDENCE_DIR="$evidence_dir")"

    assert_eq "$exit_code" "0" "explicit FJCLOUD_SECRET_FILE should override default secret path"
    assert_contains "$(cat "$stdout_file")" "PREREQUISITES_OK" \
        "success output should emit stable pass token"

    status_doc="$evidence_dir/PREREQUISITE_STATUS.md"
    assert_file_exists "$status_doc" "success path should write prerequisite status"
    assert_contains "$(cat "$status_doc")" "Secret source: $override_secret_file" \
        "status doc should record secret source path"
    assert_contains "$(cat "$status_doc")" "STRIPE_SECRET_KEY_RESTRICTED: present" \
        "status doc should record restricted key presence"
    assert_contains "$(cat "$status_doc")" "STRIPE_RESTRICTED_KEY_ID: present" \
        "status doc should record restricted key id marker"
    assert_contains "$(cat "$status_doc")" "STRIPE_OLD_KEY_ID: present" \
        "status doc should record old key id marker"

    after_default_bundle_count="$(count_cutover_bundles "$isolated_repo")"
    if [ "$after_default_bundle_count" != "$before_default_bundle_count" ]; then
        fail "test evidence override should avoid creating default tracked cutover bundle"
    else
        pass "test evidence override should avoid creating default tracked cutover bundle"
    fi
}

test_uses_default_repo_secret_file_when_override_unset() {
    local tmp_dir isolated_repo script_path repo_secret_dir repo_secret_file evidence_dir stdout_file stderr_file exit_code status_doc
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    isolated_repo="$(create_isolated_prereq_repo "$tmp_dir")"
    script_path="$isolated_repo/scripts/stripe_cutover_prereqs.sh"
    repo_secret_dir="$isolated_repo/.secret"
    repo_secret_file="$repo_secret_dir/.env.secret"
    evidence_dir="$tmp_dir/evidence"
    stdout_file="$tmp_dir/stdout.txt"
    stderr_file="$tmp_dir/stderr.txt"

    mkdir -p "$repo_secret_dir"

    write_complete_secret_file "$repo_secret_file"

    exit_code="$(run_prereq_script_path "$script_path" "$stdout_file" "$stderr_file" \
        STRIPE_CUTOVER_EVIDENCE_DIR="$evidence_dir")"

    assert_eq "$exit_code" "0" "default repo secret file should be used when override is unset"

    status_doc="$evidence_dir/PREREQUISITE_STATUS.md"
    assert_file_exists "$status_doc" "default secret path should still write status doc"
    assert_contains "$(cat "$status_doc")" "Secret source: $repo_secret_file" \
        "status doc should record default secret path"
}

echo "=== stripe cutover prereq contract tests ==="
test_fails_when_restricted_key_missing_and_names_gap
test_enforces_comment_markers_from_raw_secret_file
test_honors_secret_file_override_and_evidence_dir_override
test_uses_default_repo_secret_file_when_override_unset

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
