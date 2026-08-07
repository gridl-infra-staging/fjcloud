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

runtime_identity_reason_for_local_owner_with_mock_curl() {
    local owned_runtime="$1" response="$2" base_url="${3:-http://flapjack.test}" tmp_dir
    tmp_dir="$(mktemp -d)"; mkdir -p "$tmp_dir/bin"
    printf '#!/usr/bin/env bash\nprintf '\''%%s'\'' '\''%s'\''\n' "$response" > "$tmp_dir/bin/curl"
    chmod +x "$tmp_dir/bin/curl"
    PATH="$tmp_dir/bin:$PATH" flapjack_runtime_identity_reason \
        "$base_url" "$owned_runtime"
    rm -rf "$tmp_dir"
}

fleet_identity_reason_with_mock_curl() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"; mkdir -p "$tmp_dir/bin"
    # The mock runs as a separate process, so the pin has to be exported rather
    # than interpolated: the heredoc is quoted to protect the mock's own "$*"
    # and "$1", and ${FJCLOUD_FLAPJACK_VERSION} is therefore expanded when the
    # mock runs. These fixtures differ from each other by REVISION, which is the
    # drift this helper exists to detect; their version must track the pin so a
    # bump does not turn every case into version_mismatch.
    export FJCLOUD_FLAPJACK_VERSION
    cat > "$tmp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *"match-one"*) printf '%s' '{"version":"'"$FJCLOUD_FLAPJACK_VERSION"'","producer_revision":"abc123","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}' ;;
    *"match-two"*) printf '%s' '{"version":"'"$FJCLOUD_FLAPJACK_VERSION"'","producer_revision":"abc123","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}' ;;
    *"drifted"*) printf '%s' '{"version":"'"$FJCLOUD_FLAPJACK_VERSION"'","producer_revision":"def456","build_id":"build-1","dirty":false,"capabilities":["preview_events_v1"]}' ;;
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

# ---------------------------------------------------------------------------
# Shared version-floor specification
# ---------------------------------------------------------------------------
# The Flapjack runtime version rule is implemented TWICE, in two languages:
# here (scripts/lib/local_stack_contract.sh, Python) and in Rust
# (infra/api/src/services/flapjack_proxy/mod.rs). Nothing used to tie them
# together, so a change to one could not fail the other. Both suites now read
# the SAME fixture file, which is the spec.
#
# Each case is fed as a version-only /health payload with every other identity
# requirement blank, so the ONLY thing under test is the version comparison —
# no revision, build-id, dirty or capability check can mask the result.
version_floor_cases_file="$REPO_ROOT/scripts/tests/fixtures/flapjack_version_floor_cases.json"
[ -f "$version_floor_cases_file" ] || fail "shared version-floor fixture is missing: $version_floor_cases_file"
version_floor_expected_rows="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cases"]))' "$version_floor_cases_file")"
version_floor_seen_rows=0
# Field separator is ASCII Unit Separator, NOT tab: bash collapses runs of
# IFS *whitespace* into one delimiter, which silently merged the empty-floor
# row's blank field and shifted every column right.
while IFS=$'\x1f' read -r case_observed case_floor case_expect; do
    version_floor_seen_rows=$((version_floor_seen_rows + 1))
    version_floor_actual="$(
        FJCLOUD_FLAPJACK_VERSION="$case_floor" \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION="" \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="" \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256="" \
        FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY="" \
        flapjack_classify_health_json "{\"version\":\"$case_observed\"}"
    )"
    assert_eq "$version_floor_actual" "$case_expect" \
        "shared version-floor spec: observed=$case_observed floor=${case_floor:-<unset>}"
done < <(python3 -c '
import json, sys

for case in json.load(open(sys.argv[1]))["cases"]:
    print("\x1f".join([case["observed"], case["floor"], case["expect"]]))
' "$version_floor_cases_file")
# A silently-empty loop would let this whole block "pass" while testing nothing.
assert_eq "$version_floor_seen_rows" "$version_floor_expected_rows" \
    "every shared version-floor case must actually be exercised"

# Health fixtures derive their version from the pin rather than restating it.
# A restated literal goes stale the moment the pin moves, and because the version
# check runs FIRST in the classifier, a stale literal makes every one of these
# fixtures report version_mismatch — masking the revision/build-id/capability
# behaviour each of them actually exists to test.
clean_health="{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"producer_revision\":\"abc123\",\"build_id\":\"build-1\",\"dirty\":false,\"capabilities\":[\"preview_events_v1\"]}"
missing_dirty_health="{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"producer_revision\":\"abc123\",\"build_id\":\"build-1\",\"capabilities\":[\"preview_events_v1\"]}"
revision_health="{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"producer_revision\":\"def456\",\"build_id\":\"build-1\",\"dirty\":false,\"capabilities\":[\"preview_events_v1\"]}"
build_health="{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"producer_revision\":\"abc123\",\"build_id\":\"build-2\",\"dirty\":false,\"capabilities\":[\"preview_events_v1\"]}"
missing_capability_health="{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"producer_revision\":\"abc123\",\"build_id\":\"build-1\",\"dirty\":false,\"capabilities\":[]}"
legacy_health="{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\"}"

test_selected_binary_artifact_identity_accepts_public_health_projection() {
    local tmp_dir binary_path receipt_path reason binary_sha public_health
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
    public_health="{\"status\":\"ok\",\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"build\":{\"schemaVersion\":1,\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"profile\":\"debug\",\"capabilities\":{\"preview_events_v1\":true}},\"capabilities\":{\"preview_events_v1\":true}}"

    export FJCLOUD_FLAPJACK_REQUIRED_REVISION="stale-shell-revision"
    export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="stale-shell-build"
    unset FJCLOUD_FLAPJACK_REQUIRED_SHA256
    FLAPJACK_BINARY_PROVENANCE="source-receipt:$receipt_path" \
        flapjack_export_required_artifact_identity "$binary_path"

    reason="$(runtime_identity_reason_with_mock_curl "$public_health")"
    assert_eq "$reason" "match" \
        "receipt-backed selected binary should accept the engine's intentionally public health projection"
    assert_eq "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" "$binary_sha" \
        "selected binary should retain its receipt-backed artifact checksum requirement"
    assert_eq "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" "" \
        "artifact identity must not auto-require private runtime revision evidence"
    assert_eq "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" "" \
        "artifact identity must not auto-require private runtime build-id evidence"
}

test_selected_binary_artifact_identity_accepts_public_health_projection
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
real_nested_health="{\"status\":\"ok\",\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"build\":{\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"revision\":\"abc123\",\"dirty\":false,\"workspaceDigest\":\"build-1\",\"capabilities\":{\"preview_events_v1\":true}},\"capabilities\":{\"preview_events_v1\":true}}"
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
current_public_health="{\"status\":\"ok\",\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"build\":{\"schemaVersion\":1,\"version\":\"$FJCLOUD_FLAPJACK_VERSION\",\"profile\":\"debug\",\"capabilities\":{\"preview_events_v1\":true}},\"capabilities\":{\"preview_events_v1\":true}}"
assert_eq "$(runtime_identity_reason_for_local_owner_with_mock_curl "1" "$current_public_health")" "match" \
    "a wrapper-owned receipt-validated runtime should accept the current public Flapjack health contract"
assert_eq "$(runtime_identity_reason_for_local_owner_with_mock_curl "0" "$current_public_health")" "legacy_malformed_health" \
    "a pre-existing runtime should still require exact identity fields in health"
assert_eq "$(fleet_identity_reason_with_mock_curl http://match-one http://match-two)" "match" \
    "all-match fleets should classify as match"
assert_eq "$(fleet_identity_reason_with_mock_curl http://match-one http://drifted)" "mixed_fleet" \
    "a single region or node with different exact identity should classify as mixed_fleet"

# ---------------------------------------------------------------------------
# Rejection message content is a deliverable, not decoration
# ---------------------------------------------------------------------------
# The previous messages told the reader to "rebuild the checkout", which cannot
# change a version, and never named the version actually observed. That is what
# made a rejection look like noise worth working around. These assert the facts
# an operator needs to act correctly, so deleting them fails the suite.
rejection_message_with_mock_curl() {
    local reason="$1" health="$2" tmp_dir out
    tmp_dir="$(mktemp -d)"; mkdir -p "$tmp_dir/bin"
    printf '#!/usr/bin/env bash\nprintf '\''%%s'\'' '\''%s'\''\n' "$health" > "$tmp_dir/bin/curl"
    chmod +x "$tmp_dir/bin/curl"
    out="$(PATH="$tmp_dir/bin:$PATH" flapjack_identity_rejection_message \
        "$reason" "http://flapjack.test" "/selected/flapjack")"
    rm -rf "$tmp_dir"
    printf '%s' "$out"
}

too_old_message="$(rejection_message_with_mock_curl version_mismatch '{"version":"0.9.9"}')"
assert_contains "$too_old_message" "0.9.9" \
    "a rejection must name the version the engine actually reported"
assert_contains "$too_old_message" "$FJCLOUD_FLAPJACK_VERSION" \
    "a rejection must name the floor it was measured against"
assert_contains "$too_old_message" "/selected/flapjack" \
    "a rejection must name the binary that was selected"
assert_contains "$too_old_message" "MINIMUM" \
    "a rejection must state that the pin is a floor, so newer engines are not the problem"
assert_contains "$too_old_message" "OLDER checkout" \
    "a rejection must explicitly rule out repointing at an older checkout"
assert_contains "$too_old_message" "published flapjack release" \
    "the too-old remedy must warn that lowering the floor requires a published release"

unparseable_message="$(rejection_message_with_mock_curl version_unparseable '{"version":"1.0.12-rc.1"}')"
assert_contains "$unparseable_message" "1.0.12-rc.1" \
    "an unparseable rejection must quote the version it could not order"
assert_contains "$unparseable_message" "prerelease" \
    "an unparseable rejection must explain WHY the version could not be ordered"
assert_not_contains "$unparseable_message" "published flapjack release" \
    "an unparseable version must not be given the too-old remedy"

local_dev_text="$(cat "$REPO_ROOT/scripts/local-dev-up.sh")"
preflight_text="$(cat "$REPO_ROOT/scripts/e2e-preflight.sh")"
playwright_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"
assert_contains "$local_dev_text" 'flapjack_runtime_identity_reason' "local dev startup enforces the shared Flapjack identity classifier"
assert_contains "$local_dev_text" 'flapjack_export_required_artifact_identity "$FLAPJACK_BIN"' \
    "local dev startup should derive only artifact evidence before checking public health"
assert_contains "$preflight_text" 'api_supports_capability' "browser preflight enforces the API capability contract"
assert_contains "$playwright_text" 'flapjack_runtime_identity_reason' "Playwright stack enforces the shared Flapjack identity classifier"
assert_contains "$playwright_text" 'flapjack_export_required_artifact_identity "$flapjack_bin"' \
    "Playwright startup should derive only artifact evidence before checking public health"
assert_contains "$playwright_text" 'api_supports_capability' "Playwright stack enforces the API capability contract"
# Both launchers must route through the one message owner. Two hand-written
# messages is how they drifted into saying different, equally unactionable things.
assert_contains "$local_dev_text" 'flapjack_identity_rejection_message' \
    "local dev startup reports rejections through the shared message owner"
assert_contains "$playwright_text" 'flapjack_identity_rejection_message' \
    "Playwright stack reports rejections through the shared message owner"
run_test_summary
