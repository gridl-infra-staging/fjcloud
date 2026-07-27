#!/usr/bin/env bash
# Live setup and topology cases sourced by local_multinode_migration_probe_test.sh.

write_stubbed_live_command() {
    local path="$1" command_name="$2" body="$3"
    write_mock_script "$path" \
        "printf '%s\\n' '$command_name called' >> \"\$LOCAL_MULTINODE_STUB_LOG\"; $body"
}

write_live_stub_bin_dir() {
    local stub_dir="$1" docker_body="${2:-exit 0}" curl_body="${3:-exit 97}"
    mkdir -p "$stub_dir"
    write_stubbed_live_command "$stub_dir/docker" docker "$docker_body"
    write_stubbed_live_command "$stub_dir/curl" curl "$curl_body"
    write_stubbed_live_command "$stub_dir/aws" aws "exit 98"
    write_stubbed_live_command "$stub_dir/psql" psql "exit 98"
    write_stubbed_live_command "$stub_dir/ssh" ssh "exit 98"
}

write_fake_flapjack_checkout() {
    local root="$1"
    mkdir -p "$root/target/debug"
    touch "$root/Cargo.toml"
    write_mock_script "$root/target/debug/flapjack" "sleep 60"
}

write_algolia_secret_fixture() {
    local path="$1"
    {
        printf 'ALGOLIA_APP_ID=fixture-app\n'
        printf 'ALGOLIA_ADMIN_KEY=fixture-admin-key\n'
    } > "$path"
}

run_live_probe() {
    local evidence_path="$1" out_path="$2" err_path="$3" rc_path="$4"
    shift 4
    set +e
    env "$@" bash "$PROBE" --run-live "$evidence_path" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" > "$rc_path"
    set -e
}

write_probe_function_library() {
    local output="$1"
    {
        printf 'SCRIPT_DIR=%q\n' "$REPO_ROOT/scripts"
        printf 'REPO_ROOT=%q\n' "$REPO_ROOT"
        sed -n '/^OWNED_ALGOLIA_INDEXES=/,/^case "${1:-}" in/{/^case "${1:-}" in/q;p;}' \
            "$PROBE"
    } > "$output"
}

run_probe_function_harness() {
    local body="$1" out_path="$2" err_path="$3" rc_path="$4" tmp library harness
    tmp="$(mktemp -d)"
    register_tmp_path "$tmp"
    library="$tmp/probe_functions.sh"
    harness="$tmp/harness.sh"
    write_probe_function_library "$library"
    {
        printf 'set -euo pipefail\n'
        printf 'source %q\n' "$library"
        printf '%s\n' "$body"
    } > "$harness"
    set +e
    bash "$harness" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" > "$rc_path"
    set -e
}

assert_live_preflight_failure() {
    local label="$1" expected_rc="$2" expected_diagnostic="$3"
    local evidence_path="$4" out="$5" err="$6" rc="$7" log="$8"

    assert_eq "$(cat "$rc")" "$expected_rc" "$label exits nonzero"
    assert_file_empty_bytes "$out" "$label emits no stdout bytes"
    assert_contains "$(cat "$err")" "$expected_diagnostic" "$label emits stable diagnostic"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "$label diagnostic omits paths and secret-like material"
    if [ -e "$evidence_path" ] && [ ! -d "$evidence_path" ]; then
        assert_file_empty_bytes "$evidence_path" "$label leaves evidence empty"
    fi
    assert_not_contains "$(cat "$log")" "curl called" "$label performs no live HTTP side effect"
    assert_not_contains "$(cat "$log")" "aws called" "$label performs no AWS side effect"
    assert_not_contains "$(cat "$log")" "psql called" "$label performs no database side effect"
    assert_not_contains "$(cat "$log")" "ssh called" "$label performs no SSH side effect"
}

test_run_live_preflight_failures_are_side_effect_free() {
    local tmp stub_dir out err rc log evidence flapjack_dir secret_file
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stub_dir="$tmp/bin"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    log="$tmp/live_calls.log"
    evidence="$tmp/evidence.json"
    flapjack_dir="$tmp/flapjack"
    secret_file="$tmp/.env.secret"
    : > "$log"
    write_fake_flapjack_checkout "$flapjack_dir"
    write_algolia_secret_fixture "$secret_file"

    write_live_stub_bin_dir "$stub_dir" "exit 1"
    run_live_probe "$evidence" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$secret_file"
    assert_live_preflight_failure "missing docker" "2" "docker daemon unavailable" \
        "$evidence" "$out" "$err" "$rc" "$log"

    : > "$log"; : > "$out"; : > "$err"; : > "$rc"; : > "$evidence"
    write_live_stub_bin_dir "$stub_dir" "exit 0"
    run_live_probe "$evidence" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        FLAPJACK_DEV_DIR="$tmp/missing-flapjack" FJCLOUD_SECRET_FILE="$secret_file"
    assert_live_preflight_failure "missing FLAPJACK_DEV_DIR" "2" "FLAPJACK_DEV_DIR is invalid" \
        "$evidence" "$out" "$err" "$rc" "$log"

    : > "$log"; : > "$out"; : > "$err"; : > "$rc"; : > "$evidence"
    write_live_stub_bin_dir "$stub_dir" "exit 0"
    run_live_probe "$evidence" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$tmp/missing-secret"
    assert_live_preflight_failure "missing Algolia credentials" "2" "Algolia credentials unavailable" \
        "$evidence" "$out" "$err" "$rc" "$log"

    : > "$log"; : > "$out"; : > "$err"; : > "$rc"; : > "$evidence"
    run_live_probe "$evidence" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$secret_file"
    assert_live_preflight_failure "missing HA no-auth opt-in" "2" \
        "refusing unauthenticated HA bind without LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1" \
        "$evidence" "$out" "$err" "$rc" "$log"

    : > "$log"; : > "$out"; : > "$err"; : > "$rc"
    run_live_probe "$tmp" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$secret_file"
    assert_eq "$(cat "$rc")" "2" "directory evidence path is rejected"
    assert_file_empty_bytes "$out" "directory evidence path emits no stdout bytes"
    assert_contains "$(cat "$err")" "evidence path is not writable" \
        "directory evidence path emits stable diagnostic"
    assert_eq "$(cat "$log")" "" "directory evidence path is rejected before command probes"

    local unwritable_dir
    unwritable_dir="$tmp/unwritable"
    mkdir "$unwritable_dir"
    chmod 500 "$unwritable_dir"
    : > "$log"; : > "$out"; : > "$err"; : > "$rc"
    run_live_probe "$unwritable_dir/evidence.json" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$secret_file"
    chmod 700 "$unwritable_dir"
    assert_eq "$(cat "$rc")" "2" "unwritable evidence path is rejected"
    assert_file_empty_bytes "$out" "unwritable evidence path emits no stdout bytes"
    assert_contains "$(cat "$err")" "evidence path is not writable" \
        "unwritable evidence path emits stable diagnostic"
    assert_eq "$(cat "$log")" "" "unwritable evidence path is rejected before command probes"
}

test_run_live_rejects_malformed_captured_json() {
    local tmp out err rc evidence malformed body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    evidence="$tmp/evidence.json"
    malformed="$tmp/malformed.json"
    printf '{not-json' > "$malformed"
    body="
EVIDENCE_CLASSIFIER='$REPO_ROOT/scripts/lib/local_multinode_migration_evidence.py'
validate_captured_live_evidence '$malformed' '$evidence'
"
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "1" "malformed live JSON exits nonzero"
    assert_file_empty_bytes "$out" "malformed live JSON emits no stdout bytes"
    assert_contains "$(cat "$err")" "captured evidence failed validation" \
        "malformed live JSON emits stable diagnostic"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "malformed live JSON diagnostic omits paths and secret-like material"
    [ ! -e "$evidence" ] || assert_file_empty_bytes "$evidence" \
        "malformed live JSON leaves operator evidence empty"
}

test_run_live_fails_closed_on_unsupported_overwrite_owner() {
    local tmp stub_dir out err rc log evidence flapjack_dir secret_file handler
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stub_dir="$tmp/bin"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    log="$tmp/live_calls.log"; evidence="$tmp/evidence.json"
    flapjack_dir="$tmp/flapjack"; secret_file="$tmp/.env.secret"
    handler="$flapjack_dir/engine/flapjack-http/src/handlers/migration/mod.rs"
    : > "$log"
    write_fake_flapjack_checkout "$flapjack_dir"
    mkdir -p "$(dirname "$handler")"
    printf '%s\n' \
        'route /1/migrations/algolia /1/migrations/algolia/{job_id}' \
        'overwrite=true is not supported by Algolia migration import' > "$handler"
    write_algolia_secret_fixture "$secret_file"
    write_live_stub_bin_dir "$stub_dir" "exit 0"

    run_live_probe "$evidence" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1 \
        FLAPJACK_BINARY_PROVENANCE="revision:0123456789abcdef0123456789abcdef01234567" \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$secret_file"

    assert_eq "$(cat "$rc")" "2" "unsupported overwrite owner exits nonzero"
    assert_file_empty_bytes "$out" "unsupported overwrite owner emits no stdout bytes"
    assert_contains "$(cat "$err")" "Flapjack migration contract is incompatible" \
        "unsupported overwrite owner emits a stable fail-closed diagnostic"
    assert_file_empty_bytes "$evidence" "unsupported overwrite owner leaves evidence empty"
    assert_not_contains "$(cat "$log")" "curl called" \
        "unsupported overwrite owner fails before live HTTP side effects"
}

test_live_source_fixtures_have_exact_object_ids() {
    local create_fixture overwrite_fixture stale_fixture
    create_fixture="$FIXTURE_DIR/live_create_source.json"
    overwrite_fixture="$FIXTURE_DIR/live_overwrite_source.json"
    stale_fixture="$FIXTURE_DIR/live_stale_destination.json"

    if python3 - "$create_fixture" "$overwrite_fixture" "$stale_fixture" <<'PY'
import json
import sys
from pathlib import Path

create = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
overwrite = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
stale = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))

assert [item["objectID"] for item in create] == ["create-doc-1", "create-doc-2"]
assert [item["objectID"] for item in overwrite] == [
    "overwrite-doc-1",
    "overwrite-doc-2",
    "overwrite-doc-3",
]
assert [item["objectID"] for item in stale] == ["stale-destination-doc"]
assert all(isinstance(item, dict) and len(item) >= 2 for item in create + overwrite + stale)
PY
    then
        pass "live source fixtures pin exact create, overwrite, and stale object IDs"
    else
        fail "live source fixtures pin exact create, overwrite, and stale object IDs"
    fi
}

test_live_plan_reuses_identity_and_secret_config_owners() {
    if PROBE_SOURCE="$PROBE" python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["PROBE_SOURCE"]).read_text(encoding="utf-8")
required_calls = [
    'flapjack_export_required_artifact_identity "$FLAPJACK_BIN"',
    'flapjack_source_provenance_summary',
    'algolia_import_probe_write_header_config "$ALGOLIA_AUTH_CONFIG"',
    'algolia_import_probe_secure_temp_file "$RUNTIME_DIR"',
]
assert all(call in source for call in required_calls)
assert 'RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)_${repo_short_sha}_$$"' in source
assert 'CREATE_SOURCE_INDEX="${RUN_PREFIX}_create_source"' in source
assert 'OVERWRITE_TARGET_INDEX="${RUN_PREFIX}_overwrite_target"' in source
PY
    then
        pass "live plan reuses identity/config owners and safe timestamped names"
    else
        fail "live plan reuses identity/config owners and safe timestamped names"
    fi
}

test_live_helper_rejects_public_peer_host() {
    if LIVE_HELPER="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py" python3 - <<'PY'
import contextlib
import importlib.util
import io
import os

spec = importlib.util.spec_from_file_location("live_helper", os.environ["LIVE_HELPER"])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

class FakeSocket:
    def __init__(self, host: str):
        self._host = host
    def connect(self, target):
        return None
    def getsockname(self):
        return (self._host, 43210)
    def close(self):
        return None

module.socket.socket = lambda *args, **kwargs: FakeSocket("8.8.8.8")
public_out = io.StringIO()
with contextlib.redirect_stdout(public_out):
    assert module.safe_peer_host([]) == 1
assert public_out.getvalue() == ""

module.socket.socket = lambda *args, **kwargs: FakeSocket("10.0.0.8")
private_out = io.StringIO()
with contextlib.redirect_stdout(private_out):
    assert module.safe_peer_host([]) == 0
assert private_out.getvalue().strip() == "10.0.0.8"
PY
    then
        pass "live helper rejects public peer IPs and allows private ones"
    else
        fail "live helper rejects public peer IPs and allows private ones"
    fi
}

test_standalone_starter_reuses_local_stack_launch_shape() {
    if PROBE_SOURCE="$PROBE" python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["PROBE_SOURCE"]).read_text(encoding="utf-8")
required = [
    'start_standalone_flapjack()',
    'FLAPJACK_NO_AUTH=1 nohup "$FLAPJACK_BIN"',
    '--port "$port"',
    '--data-dir "$data_dir"',
    'wait_for_health "http://127.0.0.1:${port}/health"',
    'STANDALONE_DOCKER=false',
]
assert all(fragment in source for fragment in required)
PY
    then
        pass "standalone starter reuses the local stack launch shape without Docker"
    else
        fail "standalone starter reuses the local stack launch shape without Docker"
    fi
}

test_algolia_seeding_tracks_every_remote_owner() {
    if PROBE_SOURCE="$PROBE" python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["PROBE_SOURCE"]).read_text(encoding="utf-8")
required = [
    'seed_algolia_index "$CREATE_SOURCE_INDEX" "$LIVE_CREATE_FIXTURE"',
    'seed_algolia_index "$OVERWRITE_SOURCE_INDEX" "$LIVE_OVERWRITE_FIXTURE"',
    'create_restricted_algolia_key "$CREATE_SOURCE_INDEX" "$OVERWRITE_SOURCE_INDEX"',
    'OWNED_ALGOLIA_INDEXES+=("$index")',
    'OWNED_ALGOLIA_KEYS+=("$restricted_key")',
    'PUT "/1/indexes/$index/settings" "$payload"',
    '"searchableAttributes":["title"],"attributesForFaceting":["category"]',
    'algolia_import_probe_wait_for_restricted_source_key',
]
assert all(fragment in source for fragment in required)
PY
    then
        pass "Algolia seeding reuses fixtures and tracks every index and key"
    else
        fail "Algolia seeding reuses fixtures and tracks every index and key"
    fi
}

test_secure_temp_files_are_tracked_in_parent_shell() {
    if PROBE_SOURCE="$PROBE" python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["PROBE_SOURCE"]).read_text(encoding="utf-8")
assert "new_owned_runtime_file()" in source
assert 'printf -v "$destination_name" \'%s\' "$path"' in source
assert source.count('new_owned_runtime_file ') >= 3
PY
    then
        pass "live helpers track temporary files in the parent shell"
    else
        fail "live helpers track temporary files in the parent shell"
    fi
}

test_standalone_specimens_use_async_owner_and_parity_oracle() {
    if PROBE_SOURCE="$PROBE" python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["PROBE_SOURCE"]).read_text(encoding="utf-8")
required = [
    'flapjack_request "202" POST "/1/migrations/algolia" "$payload"',
    'flapjack_request "200" GET "/1/migrations/algolia/$job_id"',
    'python3 "$PARITY_ORACLE" --source "$source_hits_file" --migrated "$hits_file"',
    'run_standalone_migration "$CREATE_SOURCE_INDEX" "$CREATE_TARGET_INDEX" false',
    'run_standalone_migration "$OVERWRITE_SOURCE_INDEX" "$OVERWRITE_TARGET_INDEX" true',
    'seed_stale_flapjack_target',
    'assert_parity_report "$CREATE_PARITY_REPORT" 2 "create-doc-1,create-doc-2"',
    'assert_parity_report "$OVERWRITE_PARITY_REPORT" 3 "overwrite-doc-1,overwrite-doc-2,overwrite-doc-3"',
    'assert_stale_destination_absent',
]
assert all(fragment in source for fragment in required)
PY
    then
        pass "standalone specimens bind async submit/status, exact parity, and stale absence"
    else
        fail "standalone specimens bind async submit/status, exact parity, and stale absence"
    fi
}

test_negative_modes_reuse_live_runner_and_expected_red_finalizer() {
    if PROBE_SOURCE="$PROBE" \
        LIVE_HELPER="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py" \
        LIVE_MODES="$REPO_ROOT/scripts/lib/local_multinode_migration_live_modes.sh" \
        python3 - <<'PY'
import os
from pathlib import Path

source = "\n".join(
    Path(os.environ[name]).read_text(encoding="utf-8")
    for name in ("PROBE_SOURCE", "LIVE_HELPER", "LIVE_MODES")
)
required = [
    'run_live_mode "$2" negative_ha_vs_standalone',
    'run_live_mode "$2" negative_stale_survivor',
    'run_live_sequence "$scenario_mode" "$evidence_path"',
    'finalize_live_evidence "$scenario_mode" "$evidence_path"',
    'finalize_expected_red_evidence "$evidence_path"',
    'preserve_negative_ha_vs_standalone_evidence',
    'preserve_negative_stale_survivor_evidence',
    'rebind-ha-refusal-peer-count',
    'stale-destination-doc',
]
for fragment in required:
    assert fragment in source, fragment
sequence = source.split("run_live_sequence()", 1)[1]
positive = sequence.index('prepare_live_plan')
for fragment in [
    'seed_live_algolia_sources',
    'start_standalone_flapjack',
    'run_standalone_specimens',
    'start_peer_connected_flapjack',
    'run_ha_refusal_specimens',
    'write_live_evidence',
    'cleanup_owned_resources',
    'stamp-cleanup',
    'finalize_live_evidence',
]:
    found = sequence.index(fragment)
    assert positive <= found, fragment
    positive = found
assert 'run_live_sequence "$scenario_mode" "$evidence_path"' in source
PY
    then
        pass "negative modes reuse live sequencing and expected-RED evidence finalization"
    else
        fail "negative modes reuse live sequencing and expected-RED evidence finalization"
    fi
}

test_expected_red_finalizer_preserves_failing_evidence() {
    local tmp out err rc evidence body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    evidence="$tmp/evidence.json"
    printf '{"kept":true}\n' > "$evidence"
    body="
classify_evidence() {
    printf '%s\n' 'LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_peer_count_invalid'
    return 1
}
finalize_expected_red_evidence '$evidence'
"
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "1" "expected-RED finalizer returns classifier rc 1"
    assert_stdout_exact_status_line "$out" \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_peer_count_invalid" \
        "expected-RED finalizer prints the classifier status line"
    assert_contains "$(cat "$evidence")" '"kept":true' \
        "expected-RED finalizer preserves failing evidence JSON"
    assert_file_empty_bytes "$err" "expected-RED finalizer emits no stderr on intended red"
}

test_standalone_specimens_browse_live_sources_before_parity() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
RUNTIME_DIR="$(mktemp -d)"
LIVE_CREATE_FIXTURE="'"$FIXTURE_DIR"'/live_create_source.json"
LIVE_OVERWRITE_FIXTURE="'"$FIXTURE_DIR"'/live_overwrite_source.json"
EVENTS_FILE="$RUNTIME_DIR/events"
: > "$EVENTS_FILE"
new_owned_runtime_file() {
    local destination_name="$1" path
    path="$RUNTIME_DIR/${destination_name}.json"
    : > "$path"
    printf -v "$destination_name" "%s" "$path"
}
record_event() { printf "%s\n" "$1" >> "$EVENTS_FILE"; }
run_standalone_migration() { record_event "migrate:$1:$2:$3:$4"; }
seed_stale_flapjack_target() { record_event "seed-stale"; }
browse_algolia_index() {
    local index="$1" output="$2"
    record_event "browse-source:${index}:${output}"
    case "$index" in
        create_source) cp "$LIVE_CREATE_FIXTURE" "$output" ;;
        overwrite_source) cp "$LIVE_OVERWRITE_FIXTURE" "$output" ;;
        *) return 1 ;;
    esac
}
browse_flapjack_index() {
    local index="$1" output="$2"
    record_event "browse-target:${index}:${output}"
    case "$index" in
        create_target) cp "$CREATE_SOURCE_HITS_FILE" "$output" ;;
        overwrite_target) cp "$OVERWRITE_SOURCE_HITS_FILE" "$output" ;;
        *) return 1 ;;
    esac
}
python3() {
    if [ "$1" = "$PARITY_ORACLE" ]; then
        shift
        command python3 "$PARITY_ORACLE" "$@"
        return $?
    fi
    command python3 "$@"
}
CREATE_SOURCE_INDEX=create_source
CREATE_TARGET_INDEX=create_target
OVERWRITE_SOURCE_INDEX=overwrite_source
OVERWRITE_TARGET_INDEX=overwrite_target
LIVE_STALE_FIXTURE="'"$FIXTURE_DIR"'/live_stale_destination.json"
PARITY_ORACLE="'"$REPO_ROOT"'/scripts/lib/algolia_migration_parity.py"
assert_stale_destination_absent() { record_event "assert-stale-absent"; }
run_standalone_specimens
cat "$EVENTS_FILE"
printf "CREATE_SOURCE_HITS_FILE=%s\n" "${CREATE_SOURCE_HITS_FILE:-}"
printf "OVERWRITE_SOURCE_HITS_FILE=%s\n" "${OVERWRITE_SOURCE_HITS_FILE:-}"
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" \
        "standalone specimens require observed source browse before parity"
    assert_contains "$(cat "$out")" "browse-source:create_source:" \
        "create specimen browses the live Algolia source"
    assert_contains "$(cat "$out")" "browse-source:overwrite_source:" \
        "overwrite specimen browses the live Algolia source"
    assert_contains "$(cat "$out")" "CREATE_SOURCE_HITS_FILE=" \
        "create source browse path is retained for evidence"
    assert_contains "$(cat "$out")" "OVERWRITE_SOURCE_HITS_FILE=" \
        "overwrite source browse path is retained for evidence"
}

test_peer_connected_live_branch_contract() {
    if PROBE_SOURCE="$PROBE" \
        LIVE_HELPER="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py" \
        LIVE_MODES="$REPO_ROOT/scripts/lib/local_multinode_migration_live_modes.sh" \
        python3 - <<'PY'
import os
from pathlib import Path

source = "\n".join(
    Path(os.environ[name]).read_text(encoding="utf-8")
    for name in ("PROBE_SOURCE", "LIVE_HELPER", "LIVE_MODES")
)
required = [
    "start_peer_connected_flapjack()",
    "# local-dev-up multi-region starts independent nodes; this probe needs connected peers.",
    "write_peer_node_config()",
    'FLAPJACK_NO_AUTH=1 nohup "$FLAPJACK_BIN"',
    '"peers": [{"node_id": peer_id, "addr": peer_url}]',
      "resolve_safe_peer_host()",
      "LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND",
      'seed_bind_addr="${peer_host}:${seed_port}"',
      'target_bind_addr="${peer_host}:${target_port}"',
      'HA_TARGET_URL="http://${target_bind_addr}"',
    '--bind-addr "$bind_addr"',
    'FLAPJACK_ALLOW_NO_AUTH_PUBLIC_BIND=1',
    'FLAPJACK_STARTUP_CATCHUP_STRICT=0',
    'start_peer_node_async "seed"',
    'wait_peer_node_health "seed"',
    'wait_for_peer_count "$HA_TARGET_URL" 1',
    'flapjack_peer_count "$HA_TARGET_URL"',
    'run_ha_refusal_specimen "$HA_TARGET_URL" "$CREATE_SOURCE_INDEX"',
    '"$CREATE_TARGET_INDEX" false',
    'run_ha_refusal_specimen "$HA_TARGET_URL" "$OVERWRITE_SOURCE_INDEX"',
    '"$OVERWRITE_TARGET_INDEX" true',
    'HTTP_STATUS="$status"',
    'classify_ha_refusal_evidence',
]
assert all(fragment in source for fragment in required)
PY
    then
        pass "peer-connected branch starts genuine peers, gates peer count, and captures both MIG-7 refusals"
    else
        fail "peer-connected branch starts genuine peers, gates peer count, and captures both MIG-7 refusals"
    fi
}

test_peer_connected_startup_executes_reachable_parallel_topology() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
body='
RUNTIME_DIR="$(mktemp -d)"
FLAPJACK_BIN=/bin/sleep
PORT_COUNTER_FILE="$RUNTIME_DIR/ports"
printf "0\n" > "$PORT_COUNTER_FILE"
events=()
config_rows=()
resolve_safe_peer_host() { printf "%s\n" "192.0.2.10"; }
choose_live_port() {
    local port_index
    port_index="$(cat "$PORT_COUNTER_FILE")"
    printf "%s\n" "$((4101 + port_index))"
    printf "%s\n" "$((port_index + 1))" > "$PORT_COUNTER_FILE"
}
new_owned_runtime_file() {
    local destination_name="$1" path
    path="$RUNTIME_DIR/${destination_name}.log"
    : > "$path"
    printf -v "$destination_name" "%s" "$path"
}
write_peer_node_config() {
    local data_dir="$1" node_id="$2" bind_addr="$3" peer_id="$4" peer_url="$5"
    config_rows+=("${node_id}|${bind_addr}|${peer_id}|${peer_url}")
    [[ "$bind_addr" == 192.0.2.10:* ]] || {
        printf "unreachable bind: %s\n" "$bind_addr" >&2
        return 1
    }
}
start_peer_node() {
    printf "legacy sequential start_peer_node was called\n" >&2
    return 1
}
start_peer_node_async() {
    local label="$1" port="$2" data_dir="$3" log_file="$4" bind_addr="$5"
    events+=("start:${label}:${bind_addr}")
}
wait_peer_node_health() {
    local label="$1" base_url="$2"
    [[ " ${events[*]} " == *" start:seed:"* && " ${events[*]} " == *" start:target:"* ]] || {
        printf "health gate before both peers launched: %s\n" "${events[*]}" >&2
        return 1
    }
    events+=("health:${label}:${base_url}")
}
wait_for_peer_count() { events+=("peer-count:$1:$2"); }
flapjack_peer_count() { printf "1\n"; }
start_peer_connected_flapjack
printf "%s\n" "${events[@]}"
printf "%s\n" "${config_rows[@]}"
printf "HA_TARGET_URL=%s\n" "$HA_TARGET_URL"
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" \
        "peer-connected startup executes without legacy sequential health gating"
    assert_contains "$(cat "$out")" "start:seed:192.0.2.10:4101" \
        "peer-connected startup launches seed on reachable advertised address"
    assert_contains "$(cat "$out")" "start:target:192.0.2.10:4102" \
        "peer-connected startup launches target on reachable advertised address"
    assert_contains "$(cat "$out")" "health:seed:http://192.0.2.10:4101" \
        "peer-connected startup gates seed health after both launches"
    assert_contains "$(cat "$out")" "health:target:http://192.0.2.10:4102/health" \
        "peer-connected startup gates target health after both launches"
    assert_contains "$(cat "$out")" "HA_TARGET_URL=http://192.0.2.10:4102" \
        "peer-connected HA target URL uses the reachable listener address"
}

test_peer_count_accepts_standalone_peers_array_contract() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
ACTIVE_FLAPJACK_URL=
flapjack_request() {
    HTTP_BODY="{\"node_id\":\"unknown\",\"replication_enabled\":false,\"peers\":[],\"autoheal_enabled\":false,\"autoheal_peers\":[]}"
}
flapjack_peer_count "http://127.0.0.1:1"
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" "peer count accepts standalone cluster status"
    assert_eq "$(cat "$out")" "0" "standalone peers array measures peer count zero"
    assert_file_empty_bytes "$err" "standalone peer count emits no diagnostic"
}

test_live_evidence_assembly_and_cleanup_contract() {
    if PROBE_SOURCE="$PROBE" \
        LIVE_HELPER="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py" \
        LIVE_MODES="$REPO_ROOT/scripts/lib/local_multinode_migration_live_modes.sh" \
        EVIDENCE_CLASSIFIER="$REPO_ROOT/scripts/lib/local_multinode_migration_evidence.py" \
        python3 - <<'PY'
import os
from pathlib import Path

source = "\n".join(
    Path(os.environ[name]).read_text(encoding="utf-8")
    for name in ("PROBE_SOURCE", "LIVE_HELPER", "LIVE_MODES", "EVIDENCE_CLASSIFIER")
)
required = [
    "write_live_evidence()",
    '"repo_sha": repo_sha',
    '"flapjack_identity": {',
    '"topology": {',
    '"ha_create_refusal": json.loads(ha_create_refusal)',
    '"ha_overwrite_refusal": json.loads(ha_overwrite_refusal)',
    '"cleanup": json.loads(cleanup)',
    '"indeterminate": True',
    "cleanup_owned_resources()",
    '"algolia_indexes"',
    '"flapjack_indexes"',
    '"algolia_keys"',
    '"local_stack"',
    '"runtime_files"',
    'GET "$(algolia_url "/1/indexes/$item")"',
    'GET "$(algolia_url "/1/keys/$item")"',
    "live_cleanup",
    'document["indeterminate"] = False',
    'finalize_live_evidence "$scenario_mode" "$evidence_path"',
    'finalize_positive_live_evidence "$evidence_path"',
]
assert all(fragment in source for fragment in required)
PY
    then
        pass "live evidence assembly writes the required redacted schema and zero cleanup counts"
    else
        fail "live evidence assembly writes the required redacted schema and zero cleanup counts"
    fi
}

test_live_evidence_uses_observed_source_browse_files() {
    if PROBE_SOURCE="$PROBE" python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["PROBE_SOURCE"]).read_text(encoding="utf-8")
required = [
    "browse_algolia_index()",
    'compare_migration_parity "$CREATE_SOURCE_HITS_FILE"',
    'compare_migration_parity "$OVERWRITE_SOURCE_HITS_FILE"',
    '"$HA_DOCKER" "$CREATE_SOURCE_HITS_FILE" "$CREATE_HITS_FILE"',
    '"$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT"',
]
for fragment in required:
    assert fragment in source, fragment
assert '"$HA_DOCKER" "$LIVE_CREATE_FIXTURE"' not in source
PY
    then
        pass "live evidence records observed source browse files, not seed fixtures"
    else
        fail "live evidence records observed source browse files, not seed fixtures"
    fi
}
