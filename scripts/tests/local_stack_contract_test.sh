#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"
source "$REPO_ROOT/scripts/lib/local_stack_contract.sh"

run_with_mock_curl() {
    local response="$1" tmp_dir status
    shift
    tmp_dir="$(mktemp -d)"; mkdir -p "$tmp_dir/bin"
    printf '#!/usr/bin/env bash\nprintf '\''%%s'\'' '\''%s'\''\n' "$response" > "$tmp_dir/bin/curl"
    chmod +x "$tmp_dir/bin/curl"
    set +e; PATH="$tmp_dir/bin:$PATH" "$@"; status=$?; set -e
    rm -rf "$tmp_dir"; return "$status"
}

runtime_identity_reason_with_mock_curl() {
    local response="$1" base_url="${2:-http://flapjack.test}" tmp_dir
    tmp_dir="$(mktemp -d)"; mkdir -p "$tmp_dir/bin"
    printf '#!/usr/bin/env bash\nprintf '\''%%s'\'' '\''%s'\''\n' "$response" > "$tmp_dir/bin/curl"
    chmod +x "$tmp_dir/bin/curl"
    PATH="$tmp_dir/bin:$PATH" flapjack_runtime_identity_reason "$base_url"
    rm -rf "$tmp_dir"
}

fleet_identity_reason_with_mock_curl() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"; mkdir -p "$tmp_dir/bin"
    cat > "$tmp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *"match-one"*) printf '%s' '{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}' ;;
    *"match-two"*) printf '%s' '{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}' ;;
    *"drifted"*) printf '%s' '{"version":"1.0.10","producer_revision":"def456","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}' ;;
    *) exit 1 ;;
esac
SH
    chmod +x "$tmp_dir/bin/curl"
    PATH="$tmp_dir/bin:$PATH" flapjack_fleet_identity_reason "$@"
    rm -rf "$tmp_dir"
}

if run_with_mock_curl '{"capabilities":["preview_events_v1"]}' api_supports_capability http://api.test preview_events_v1; then pass "API accepts advertised capability"; else fail "API should accept advertised capability"; fi
if run_with_mock_curl '{"capabilities":[]}' api_supports_capability http://api.test preview_events_v1; then fail "API should reject missing capability"; else pass "API rejects missing capability"; fi
if run_with_mock_curl "{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"capabilities\":[\"vectorSearchLocal\"]}" flapjack_runtime_matches_required_version http://flapjack.test; then pass "Flapjack accepts pinned identity"; else fail "Flapjack should accept pinned identity"; fi
if run_with_mock_curl '{"version":"0.0.1"}' flapjack_runtime_matches_required_version http://flapjack.test; then fail "Flapjack should reject wrong version"; else pass "Flapjack rejects wrong version"; fi

clean_health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}'
missing_dirty_health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","capabilities":["preview_events_v1"]}'
revision_health='{"version":"1.0.10","producer_revision":"def456","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}'
build_health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-2","dirty":false,"capabilities":["preview_events_v1"]}'
missing_capability_health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","dirty":false,"capabilities":[]}'
legacy_health='{"version":"1.0.10"}'

test_selected_binary_identity_defaults_reject_runtime_drift() {
    local tmp_dir binary_path receipt_path reason binary_sha drifted_health
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    receipt_path="$tmp_dir/source.receipt"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$binary_path"
    chmod +x "$binary_path"
    binary_sha="$(flapjack_binary_sha256 "$binary_path")"
    cat > "$receipt_path" <<'EOF'
git_revision=abc123
source_digest=build-1
dirty=clean
EOF
    printf 'binary_sha256=%s\n' "$binary_sha" >> "$receipt_path"
    drifted_health='{"version":"1.0.10","producer_revision":"def456","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}'

    unset FJCLOUD_FLAPJACK_REQUIRED_REVISION
    unset FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID
    unset FJCLOUD_FLAPJACK_REQUIRED_SHA256
    FLAPJACK_BINARY_PROVENANCE="source-receipt:$receipt_path" \
        flapjack_export_required_runtime_identity "$binary_path"

    reason="$(runtime_identity_reason_with_mock_curl "$drifted_health")"
    assert_eq "$reason" "revision_mismatch" \
        "selected binary identity should reject same-semver runtime drift without caller pre-exported required env"
}

test_selected_binary_identity_defaults_reject_runtime_drift
export FJCLOUD_FLAPJACK_REQUIRED_REVISION="abc123"
export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="build-1"
export FJCLOUD_FLAPJACK_REQUIRED_SHA256="sha-1"
export FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY="preview_events_v1"

assert_eq "$(runtime_identity_reason_with_mock_curl "$clean_health")" "match" \
    "clean matching runtime identity should be accepted"

# Regression: the identity contract previously required `build.binary_sha256` in
# /health, which the Flapjack engine deliberately never emits (see the engine's
# build_info.rs BuildInfo schema + its /health allowlist test). That made this
# classifier fail `legacy_malformed_health` for every real engine. This fixture is
# the REAL nested /health shape the engine serves (identity anchored on
# revision + workspaceDigest + dirty; NO binary sha) and must classify as match.
# The binary FILE sha256 is an artifact-layer anchor, verified where the binary is
# obtained (CI sha256sum, flapjack_binary.sh manifest/receipt) — not via /health.
real_nested_health='{"status":"ok","version":"1.0.10","build":{"version":"1.0.10","revision":"abc123","dirty":false,"workspaceDigest":"build-1","capabilities":{"preview_events_v1":true}},"capabilities":{"preview_events_v1":true}}'
assert_eq "$(runtime_identity_reason_with_mock_curl "$real_nested_health")" "match" \
    "real nested Flapjack /health (no binary_sha256) must be accepted under exact identity"
assert_eq "$(runtime_identity_reason_with_mock_curl "$missing_dirty_health")" "legacy_malformed_health" \
    "exact runtime identity should reject health without dirty-state evidence"
assert_eq "$(runtime_identity_reason_with_mock_curl "$revision_health")" "revision_mismatch" \
    "same semver with a different runtime revision should be rejected"
assert_eq "$(runtime_identity_reason_with_mock_curl "$build_health")" "build_id_mismatch" \
    "same semver with a different runtime build id should be rejected"
assert_eq "$(runtime_identity_reason_with_mock_curl "$missing_capability_health")" "missing_capability" \
    "runtime missing the required engine capability should be rejected"
assert_eq "$(runtime_identity_reason_with_mock_curl "$legacy_health")" "legacy_malformed_health" \
    "legacy version-only health should be rejected with the malformed legacy reason"
assert_eq "$(fleet_identity_reason_with_mock_curl http://match-one http://match-two)" "match" \
    "all-match fleets should classify as match"
assert_eq "$(fleet_identity_reason_with_mock_curl http://match-one http://drifted)" "mixed_fleet" \
    "a single region or node with different exact identity should classify as mixed_fleet"

local_dev_text="$(cat "$REPO_ROOT/scripts/local-dev-up.sh")"
preflight_text="$(cat "$REPO_ROOT/scripts/e2e-preflight.sh")"
playwright_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"
assert_contains "$local_dev_text" 'flapjack_runtime_identity_reason' "local dev startup enforces the shared Flapjack identity classifier"
assert_contains "$preflight_text" 'api_supports_capability' "browser preflight enforces the API capability contract"
assert_contains "$playwright_text" 'flapjack_runtime_identity_reason' "Playwright stack enforces the shared Flapjack identity classifier"
assert_contains "$playwright_text" 'api_supports_capability' "Playwright stack enforces the API capability contract"
run_test_summary
