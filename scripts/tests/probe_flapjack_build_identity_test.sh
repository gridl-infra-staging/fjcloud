#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/probe_flapjack_build_identity.sh.
#
# The probe is the single CLI entrypoint for local/remote Flapjack build-identity
# evidence. It must delegate binary SHA calculation to
# scripts/lib/flapjack_binary.sh::flapjack_binary_sha256 and runtime health
# comparison to scripts/lib/local_stack_contract.sh, then map the observation to
# one of four stable classifications: pass, real_defect, setup_infra, investigate.
#
# Every fixture is temp-directory scoped with mocked curl (local /health),
# mocked SSM exec (remote host), and mocked binary bytes so the run is unattended.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=../../scripts/lib/flapjack_binary.sh
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"

PROBE="$REPO_ROOT/scripts/probe_flapjack_build_identity.sh"

make_mock_curl_dir() {
    local response="$1" dir
    dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nprintf '\''%%s'\'' '\''%s'\''\n' "$response" > "$dir/curl"
    chmod +x "$dir/curl"
    printf '%s\n' "$dir"
}

# A mock ssm_exec_staging.sh replacement. Ignores its command argument and emits
# the canned sha256/build_info/health evidence lines the probe parses, or exits
# non-zero to simulate a missing AWS/SSM prerequisite.
make_mock_ssm() {
    local path="$1" sha="$2" build_info="$3" health="$4" exit_code="${5:-0}"
    cat > "$path" <<MOCK
#!/usr/bin/env bash
if [ "$exit_code" != "0" ]; then
    echo "ERROR: no running instance" >&2
    exit $exit_code
fi
printf 'sha256=%s\n' '$sha'
printf 'build_info=%s\n' '$build_info'
printf 'health=%s\n' '$health'
MOCK
    chmod +x "$path"
}

probe_classification() {
    printf '%s' "$1" | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
print(json.loads(lines[-1])["classification"])'
}

run_local_probe() {
    # args: binary_path health_json sha revision build_id [capability]
    local binary_path="$1" health="$2" sha="$3" revision="$4" build_id="$5"
    local capability="${6:-vectorSearchLocal}" curl_dir
    curl_dir="$(make_mock_curl_dir "$health")"
    PATH="$curl_dir:$PATH" \
        FJCLOUD_FLAPJACK_VERSION=1.0.10 \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION="$revision" \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="$build_id" \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256="$sha" \
        FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY="$capability" \
        FLAPJACK_PROBE_LOCAL_BINARY="$binary_path" \
        FLAPJACK_URL=http://flapjack.test \
        bash "$PROBE" --env local
    local status=$?
    rm -rf "$curl_dir"
    return "$status"
}

test_local_matching_identity_passes() {
    local tmp bin sha health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    bin="$tmp/flapjack"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin"; chmod +x "$bin"
    sha="$(flapjack_binary_sha256 "$bin")"
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","binary_sha256":"'"$sha"'","dirty":false,"capabilities":["vectorSearchLocal"]}'
    out="$(run_local_probe "$bin" "$health" "$sha" "abc123" "build-1")"
    assert_eq "$(probe_classification "$out")" "pass" \
        "local matching installed bytes + runtime identity should classify as pass"
}

test_local_same_semver_different_build_is_real_defect() {
    local tmp bin sha health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    bin="$tmp/flapjack"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin"; chmod +x "$bin"
    sha="$(flapjack_binary_sha256 "$bin")"
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-2","binary_sha256":"'"$sha"'","dirty":false,"capabilities":["vectorSearchLocal"]}'
    out="$(run_local_probe "$bin" "$health" "$sha" "abc123" "build-1")"
    assert_eq "$(probe_classification "$out")" "real_defect" \
        "same-semver runtime with a different build id should classify as real_defect"
}

test_local_malformed_health_is_investigate() {
    local tmp bin sha health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    bin="$tmp/flapjack"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin"; chmod +x "$bin"
    sha="$(flapjack_binary_sha256 "$bin")"
    health='{"version":"1.0.10"}'
    out="$(run_local_probe "$bin" "$health" "$sha" "abc123" "build-1")"
    assert_eq "$(probe_classification "$out")" "investigate" \
        "legacy/malformed runtime health should classify as investigate"
}

test_local_missing_binary_is_setup_infra() {
    local out
    out="$(FJCLOUD_FLAPJACK_VERSION=1.0.10 \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION=abc123 \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=build-1 \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256=sha-1 \
        FLAPJACK_PROBE_LOCAL_BINARY=/nonexistent/flapjack \
        FLAPJACK_URL=http://flapjack.test \
        bash "$PROBE" --env local)"
    assert_eq "$(probe_classification "$out")" "setup_infra" \
        "a missing selected local binary should classify as setup_infra"
}

test_remote_matching_identity_passes() {
    local tmp ssm health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    ssm="$tmp/ssm.sh"
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-1","dirty":false,"capabilities":["vectorSearchLocal"]}'
    make_mock_ssm "$ssm" "sha-remote-1" '{"version":"1.0.10","revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-1"}' "$health"
    out="$(FJCLOUD_FLAPJACK_VERSION=1.0.10 \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION=abc123 \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=build-1 \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256=sha-remote-1 \
        FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY=vectorSearchLocal \
        FLAPJACK_PROBE_SSM_EXEC="$ssm" \
        bash "$PROBE" --env staging)"
    assert_eq "$(probe_classification "$out")" "pass" \
        "remote matching installed bytes + runtime identity should classify as pass"
}

test_remote_installed_byte_mismatch_is_real_defect() {
    local tmp ssm health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    ssm="$tmp/ssm.sh"
    # Runtime /health advertises the expected identity, but the installed bytes
    # on disk hash to a different sha than the Stage 1 expected sha256.
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-1","dirty":false,"capabilities":["vectorSearchLocal"]}'
    make_mock_ssm "$ssm" "sha-remote-TAMPERED" '{"version":"1.0.10","revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-TAMPERED"}' "$health"
    out="$(FJCLOUD_FLAPJACK_VERSION=1.0.10 \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION=abc123 \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=build-1 \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256=sha-remote-1 \
        FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY=vectorSearchLocal \
        FLAPJACK_PROBE_SSM_EXEC="$ssm" \
        bash "$PROBE" --env prod)"
    assert_eq "$(probe_classification "$out")" "real_defect" \
        "remote installed bytes differing from the expected sha256 should classify as real_defect"
}

test_remote_inconsistent_build_info_is_investigate() {
    local tmp ssm health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    ssm="$tmp/ssm.sh"
    # build-info reports a sha that disagrees with the installed bytes: the host
    # evidence is internally inconsistent even though /health matches expected.
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-1","dirty":false,"capabilities":["vectorSearchLocal"]}'
    make_mock_ssm "$ssm" "sha-remote-1" '{"version":"1.0.10","revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-DISAGREE"}' "$health"
    out="$(FJCLOUD_FLAPJACK_VERSION=1.0.10 \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION=abc123 \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=build-1 \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256=sha-remote-1 \
        FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY=vectorSearchLocal \
        FLAPJACK_PROBE_SSM_EXEC="$ssm" \
        bash "$PROBE" --env staging)"
    assert_eq "$(probe_classification "$out")" "investigate" \
        "installed bytes disagreeing with build-info self-report should classify as investigate"
}

test_remote_ssm_failure_is_setup_infra() {
    local tmp ssm out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    ssm="$tmp/ssm.sh"
    make_mock_ssm "$ssm" "" "" "" 1
    out="$(FJCLOUD_FLAPJACK_VERSION=1.0.10 \
        FJCLOUD_FLAPJACK_REQUIRED_REVISION=abc123 \
        FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=build-1 \
        FJCLOUD_FLAPJACK_REQUIRED_SHA256=sha-remote-1 \
        FLAPJACK_PROBE_SSM_EXEC="$ssm" \
        bash "$PROBE" --env staging)"
    assert_eq "$(probe_classification "$out")" "setup_infra" \
        "an unreachable AWS/SSM host should classify as setup_infra"
}

test_remote_missing_expected_manifest_is_setup_infra() {
    local tmp ssm health out
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    ssm="$tmp/ssm.sh"
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","binary_sha256":"sha-remote-1","dirty":false,"capabilities":["vectorSearchLocal"]}'
    make_mock_ssm "$ssm" "sha-remote-1" '{"version":"1.0.10"}' "$health"
    # No FJCLOUD_FLAPJACK_REQUIRED_* expected identity provided.
    out="$(env -u FJCLOUD_FLAPJACK_REQUIRED_REVISION \
        -u FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID \
        -u FJCLOUD_FLAPJACK_REQUIRED_SHA256 \
        FLAPJACK_PROBE_SSM_EXEC="$ssm" \
        bash "$PROBE" --env staging)"
    assert_eq "$(probe_classification "$out")" "setup_infra" \
        "absent Stage 1 expected identity manifest/env should classify as setup_infra"
}

test_probe_artifact_omits_worktree_paths_and_is_single_json_line() {
    local tmp bin sha health out last
    tmp="$(mktemp -d)"; trap 'rm -rf "'"$tmp"'"' RETURN
    bin="$tmp/flapjack"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin"; chmod +x "$bin"
    sha="$(flapjack_binary_sha256 "$bin")"
    health='{"version":"1.0.10","producer_revision":"abc123","build_id":"build-1","binary_sha256":"'"$sha"'","dirty":false,"capabilities":["vectorSearchLocal"]}'
    out="$(run_local_probe "$bin" "$health" "$sha" "abc123" "build-1")"
    last="$(printf '%s' "$out" | python3 -c 'import sys;lines=[l for l in sys.stdin.read().splitlines() if l.strip()];print(lines[-1])')"
    assert_valid_json "$last" "probe emits a machine-parseable JSON classification line"
    assert_not_contains "$last" "$tmp" \
        "structured artifact must not leak the absolute selected-binary worktree path"
    assert_not_contains "$last" "parallel_development" \
        "structured artifact must not leak worktree-absolute paths"
}

main() {
    echo "=== flapjack build-identity probe tests ==="
    echo ""

    test_local_matching_identity_passes
    test_local_same_semver_different_build_is_real_defect
    test_local_malformed_health_is_investigate
    test_local_missing_binary_is_setup_infra
    test_remote_matching_identity_passes
    test_remote_installed_byte_mismatch_is_real_defect
    test_remote_inconsistent_build_info_is_investigate
    test_remote_ssm_failure_is_setup_infra
    test_remote_missing_expected_manifest_is_setup_infra
    test_probe_artifact_omits_worktree_paths_and_is_single_json_line

    run_test_summary
}

main "$@"
