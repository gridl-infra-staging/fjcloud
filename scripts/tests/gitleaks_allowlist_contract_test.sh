#!/usr/bin/env bash
# Contract test for narrow value-scoped exceptions in .gitleaks.toml.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GITLEAKS_CONFIG="$REPO_ROOT/.gitleaks.toml"
AWS_FIXTURE="$REPO_ROOT/scripts/reliability/fixtures/security/fake_aws_keys.txt"

PASS_COUNT=0
FAIL_COUNT=0
SUITE_TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$SUITE_TEMP_DIR"' EXIT

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

initialize_fixture_repo() {
    local fixture_repo="$1"

    mkdir -p "$fixture_repo"
    git -C "$fixture_repo" init -q
    git -C "$fixture_repo" config user.email "gitleaks-contract@example.invalid"
    git -C "$fixture_repo" config user.name "gitleaks contract"
}

commit_and_scan_fixture() {
    local fixture_repo="$1"

    git -C "$fixture_repo" add .
    git -C "$fixture_repo" commit -qm "add gitleaks contract fixture"

    SCAN_EXIT_CODE=0
    SCAN_OUTPUT="$(
        gitleaks detect \
            --source "$fixture_repo" \
            --config "$GITLEAKS_CONFIG" \
            --redact \
            --verbose \
            --exit-code=2 \
            --no-banner 2>&1
    )" || SCAN_EXIT_CODE=$?
}

test_historical_empty_algolia_multiline_specimen_is_clean() {
    local fixture_repo="$SUITE_TEMP_DIR/empty_algolia_placeholder"
    initialize_fixture_repo "$fixture_repo"
    mkdir -p "$fixture_repo/scripts"
    {
        echo 'FLAPJACK_SOURCE_REVISION=""'
        echo 'ALGOLIA_AUTH_CONFIG=""'
        echo 'STANDALONE_URL=""'
    } >"$fixture_repo/scripts/local_multinode_migration_probe.sh"

    commit_and_scan_fixture "$fixture_repo"

    assert_eq "$SCAN_EXIT_CODE" "0" \
        "historical empty ALGOLIA_AUTH_CONFIG multiline specimen is allowlisted"
    assert_not_contains "$SCAN_OUTPUT" "RuleID:" \
        "empty placeholder repository has no reported finding"
}

test_populated_algolia_value_at_historical_path_is_detected() {
    local fixture_repo="$SUITE_TEMP_DIR/populated_algolia_value"
    local credential_part_one="a3f7c9e2b8d46f10"
    local credential_part_two="c5e9b7d2a6f8304c"
    local credential="${credential_part_one}${credential_part_two}"
    initialize_fixture_repo "$fixture_repo"
    mkdir -p "$fixture_repo/scripts"
    printf 'ALGOLIA_AUTH_CONFIG=\"%s\"\nSTANDALONE_URL=\"\"\n' "$credential" \
        >"$fixture_repo/scripts/local_multinode_migration_probe.sh"

    commit_and_scan_fixture "$fixture_repo"

    assert_eq "$SCAN_EXIT_CODE" "2" \
        "populated ALGOLIA_AUTH_CONFIG remains detectable at historical path"
    assert_contains "$SCAN_OUTPUT" "RuleID:      algolia-api-key" \
        "populated Algolia control reports algolia-api-key"
    assert_contains "$SCAN_OUTPUT" "scripts/local_multinode_migration_probe.sh" \
        "populated Algolia control reports historical path"
}

test_unrelated_generic_api_key_is_detected() {
    local fixture_repo="$SUITE_TEMP_DIR/unrelated_generic_key"
    local credential_part_one="f6b2d8a4c0e79135"
    local credential_part_two="b7d3f9a5c1e80246"
    local credential="${credential_part_one}${credential_part_two}"
    initialize_fixture_repo "$fixture_repo"
    mkdir -p "$fixture_repo/config"
    printf 'service_api_key=\"%s\"\n' "$credential" \
        >"$fixture_repo/config/runtime.env"

    commit_and_scan_fixture "$fixture_repo"

    assert_eq "$SCAN_EXIT_CODE" "2" \
        "unrelated generic API key remains detectable"
    assert_contains "$SCAN_OUTPUT" "RuleID:      generic-api-key" \
        "unrelated control reports generic-api-key"
    assert_contains "$SCAN_OUTPUT" "config/runtime.env" \
        "unrelated control reports non-allowlisted path"
}

test_existing_fake_aws_fixture_is_detected_outside_allowlisted_path() {
    local fixture_repo="$SUITE_TEMP_DIR/copied_aws_fixture"
    initialize_fixture_repo "$fixture_repo"
    mkdir -p "$fixture_repo/security"
    cp "$AWS_FIXTURE" "$fixture_repo/security/copied_fake_aws_keys.txt"

    commit_and_scan_fixture "$fixture_repo"

    assert_eq "$SCAN_EXIT_CODE" "2" \
        "copied fake AWS fixture remains detectable"
    assert_contains "$SCAN_OUTPUT" "security/copied_fake_aws_keys.txt" \
        "AWS control reports non-allowlisted copied path"
    assert_contains "$SCAN_OUTPUT" "RuleID:" \
        "AWS control reports at least one finding class"
}

test_historical_empty_algolia_multiline_specimen_is_clean
test_populated_algolia_value_at_historical_path_is_detected
test_unrelated_generic_api_key_is_detected
test_existing_fake_aws_fixture_is_detected_outside_allowlisted_path

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
