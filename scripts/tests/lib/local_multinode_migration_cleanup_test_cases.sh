#!/usr/bin/env bash
# Cleanup and evidence cases sourced by local_multinode_migration_probe_test.sh.

test_cleanup_verifies_flapjack_absence_before_stopping_processes() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
RUNTIME_DIR="$(mktemp -d)"
STANDALONE_URL=http://127.0.0.1:7700
OWNED_FLAPJACK_INDEXES=(owned_index)
OWNED_FLAPJACK_PIDS=(12345)
OWNED_ALGOLIA_INDEXES=()
OWNED_ALGOLIA_KEYS=()
OWNED_CHILD_PIDS=()
OWNED_DOCKER_NETWORKS=()
OWNED_DOCKER_VOLUMES=()
OWNED_RUNTIME_FILES=()
OWNED_DATA_DIRS=()
EVENTS_FILE="$(mktemp)"
: > "$EVENTS_FILE"
record_event() { printf "%s\n" "$1" >> "$EVENTS_FILE"; }
flapjack_request() { record_event "delete-flapjack:$2:$3"; }
flapjack_index_residue_count() {
    record_event "verify-flapjack"
    printf "0\n"
}
algolia_residue_count() { printf "0\n"; }
docker_residue_count() { printf "0\n"; }
owned_pid_residue_count() { printf "0\n"; }
owned_path_residue_count() { printf "0\n"; }
kill() { record_event "stop-pid:$1"; }
wait() { :; }
set_cleanup_counts_json() { printf "counts=%s,%s,%s,%s,%s\n" "$1" "$2" "$3" "$4" "$5"; }
cleanup_owned_resources
cat "$EVENTS_FILE"
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" "cleanup harness exits zero"
    if python3 - "$out" <<'PY'
import sys
events = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert events.index("verify-flapjack") < events.index("stop-pid:12345"), events
assert events.index("delete-flapjack:DELETE:/1/indexes/owned_index") < events.index("verify-flapjack"), events
PY
    then
        pass "cleanup verifies Flapjack index absence while the server is still reachable"
    else
        fail "cleanup verifies Flapjack index absence while the server is still reachable"
    fi
}

test_cleanup_accepts_empty_owned_resource_arrays_under_nounset() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
RUNTIME_DIR="$(mktemp -d)"
STANDALONE_URL=
OWNED_FLAPJACK_INDEXES=()
OWNED_FLAPJACK_PIDS=()
OWNED_ALGOLIA_INDEXES=()
OWNED_ALGOLIA_KEYS=()
OWNED_CHILD_PIDS=()
OWNED_DOCKER_NETWORKS=()
OWNED_DOCKER_VOLUMES=()
OWNED_RUNTIME_FILES=()
OWNED_DATA_DIRS=()
algolia_residue_count() { printf "0\n"; }
docker_residue_count() { printf "0\n"; }
owned_pid_residue_count() { printf "0\n"; }
owned_path_residue_count() { printf "0\n"; }
set_cleanup_counts_json() { printf "counts=%s,%s,%s,%s,%s\n" "$1" "$2" "$3" "$4" "$5"; }
cleanup_owned_resources
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" \
        "cleanup accepts empty owned-resource arrays under nounset"
    assert_contains "$(cat "$out")" "counts=0,0,0,0,0" \
        "empty cleanup records zero residue counts"
    assert_file_empty_bytes "$err" "empty cleanup emits no nounset diagnostic"
}

test_cleanup_waits_for_algolia_key_absence_before_counting_residue() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
RUNTIME_DIR="$(mktemp -d)"
OWNED_FLAPJACK_INDEXES=()
OWNED_FLAPJACK_PIDS=()
OWNED_ALGOLIA_INDEXES=()
OWNED_ALGOLIA_KEYS=(restricted_key)
OWNED_CHILD_PIDS=()
OWNED_DOCKER_NETWORKS=()
OWNED_DOCKER_VOLUMES=()
OWNED_RUNTIME_FILES=()
OWNED_DATA_DIRS=()
key_gets=0
flapjack_index_residue_count() { printf "0\n"; }
algolia_import_probe_delete_algolia_index() { :; }
algolia_request() {
    if [ "$2" = "DELETE" ] && [ "$3" = "/1/keys/restricted_key" ]; then
        HTTP_STATUS=200
        HTTP_BODY="{}"
        return 0
    fi
    if [ "$2" = "GET" ] && [ "$3" = "/1/keys/restricted_key" ]; then
        key_gets=$((key_gets + 1))
        if [ "$key_gets" -lt 3 ]; then
            HTTP_STATUS=200
        else
            HTTP_STATUS=404
        fi
        HTTP_BODY="{}"
        return 0
    fi
    return 1
}
algolia_import_probe_wait_for_algolia_key_absence() {
    local restricted_key="$1" attempt
    for attempt in 1 2 3 4 5; do
        algolia_request "200 404" GET "/1/keys/$restricted_key" || return 1
        [ "$HTTP_STATUS" = "404" ] && return 0
    done
    return 1
}
algolia_residue_count() {
    [ "$1" = "key" ] && [ "$key_gets" -ge 3 ] && printf "0\n" && return 0
    [ "$1" = "key" ] && printf "1\n" && return 0
    printf "0\n"
}
docker_residue_count() { printf "0\n"; }
owned_pid_residue_count() { printf "0\n"; }
owned_path_residue_count() { printf "0\n"; }
set_cleanup_counts_json() {
    printf "key_gets=%s\n" "$key_gets"
    printf "counts=%s,%s,%s,%s,%s\n" "$1" "$2" "$3" "$4" "$5"
}
cleanup_owned_resources
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" "Algolia key cleanup harness exits zero"
    assert_contains "$(cat "$out")" "key_gets=3" \
        "cleanup waits for Algolia key absence before residue count"
    assert_contains "$(cat "$out")" "counts=0,0,0,0,0" \
        "cleanup records zero Algolia key residue after propagation"
}

test_run_live_preserves_evidence_inputs_until_after_assembly() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
operator_evidence="$(mktemp)"
candidate_path=""
validate_live_evidence_output_path() { : > "$1"; }
prepare_live_runtime() { RUNTIME_DIR="$(mktemp -d)"; }
algolia_import_probe_secure_temp_file() { mktemp "$RUNTIME_DIR/owned.XXXXXX"; }
require_live_docker_daemon() { :; }
require_live_flapjack_binary() { :; }
require_live_algolia_credentials() { :; }
require_live_ha_no_auth_opt_in() { :; }
prepare_live_plan() { :; }
validate_flapjack_migration_contract() { :; }
seed_live_algolia_sources() { :; }
start_standalone_flapjack() { :; }
start_peer_connected_flapjack() { :; }
run_ha_refusal_specimens() { :; }
run_standalone_specimens() {
    CREATE_HITS_FILE="$RUNTIME_DIR/create_hits.json"
    CREATE_PARITY_REPORT="$RUNTIME_DIR/create_parity.json"
    CREATE_OUTCOME_FILE="$RUNTIME_DIR/create_outcome.json"
    OVERWRITE_HITS_FILE="$RUNTIME_DIR/overwrite_hits.json"
    OVERWRITE_PARITY_REPORT="$RUNTIME_DIR/overwrite_parity.json"
    OVERWRITE_OUTCOME_FILE="$RUNTIME_DIR/overwrite_outcome.json"
    for path in "$CREATE_HITS_FILE" "$CREATE_PARITY_REPORT" "$CREATE_OUTCOME_FILE" \
        "$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT" "$OVERWRITE_OUTCOME_FILE"; do
        printf "{}\n" > "$path"
    done
}
cleanup_owned_resources() {
    rm -rf "$RUNTIME_DIR"
    CLEANUP_COUNTS_JSON="{\"algolia_indexes\":0,\"flapjack_indexes\":0,\"algolia_keys\":0,\"local_stack\":0,\"runtime_files\":0}"
}
write_live_evidence() {
    local missing=0 path
    for path in "$CREATE_HITS_FILE" "$CREATE_PARITY_REPORT" "$CREATE_OUTCOME_FILE" \
        "$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT" "$OVERWRITE_OUTCOME_FILE"; do
        [ -f "$path" ] || missing=$((missing + 1))
    done
    [ "$missing" -eq 0 ] || {
        printf "missing evidence inputs: %s\n" "$missing" >&2
        return 1
    }
    printf "{\"ok\":true}\n" > "$1"
}
validate_captured_live_evidence() {
    candidate_path="$1"
    [ "$1" = "$2" ] || cp "$1" "$2"
}
run_live_mode "$operator_evidence"
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" \
        "run-live assembles evidence from preserved inputs after cleanup"
    assert_contains "$(cat "$err")" "" \
        "run-live preservation harness emits no failure diagnostic"
}

test_run_live_records_cleanup_after_evidence_inputs_are_released() {
    local tmp out err rc body
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    body='
operator_evidence="$(mktemp)"
validate_live_evidence_output_path() { : > "$1"; }
prepare_live_runtime() { RUNTIME_DIR="$(mktemp -d)"; }
algolia_import_probe_secure_temp_file() { mktemp "$RUNTIME_DIR/owned.XXXXXX"; }
require_live_docker_daemon() { :; }
require_live_flapjack_binary() { :; }
require_live_algolia_credentials() { :; }
require_live_ha_no_auth_opt_in() { :; }
prepare_live_plan() { :; }
validate_flapjack_migration_contract() { :; }
seed_live_algolia_sources() { :; }
start_standalone_flapjack() { :; }
start_peer_connected_flapjack() { :; }
run_ha_refusal_specimens() { :; }
run_standalone_specimens() {
    CREATE_HITS_FILE="$RUNTIME_DIR/create_hits.json"
    CREATE_PARITY_REPORT="$RUNTIME_DIR/create_parity.json"
    CREATE_OUTCOME_FILE="$RUNTIME_DIR/create_outcome.json"
    OVERWRITE_HITS_FILE="$RUNTIME_DIR/overwrite_hits.json"
    OVERWRITE_PARITY_REPORT="$RUNTIME_DIR/overwrite_parity.json"
    OVERWRITE_OUTCOME_FILE="$RUNTIME_DIR/overwrite_outcome.json"
    for path in "$CREATE_HITS_FILE" "$CREATE_PARITY_REPORT" "$CREATE_OUTCOME_FILE" \
        "$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT" "$OVERWRITE_OUTCOME_FILE"; do
        printf "{}\n" > "$path"
    done
}
cleanup_owned_resources() {
    [ -z "${CANDIDATE_EVIDENCE_FILE:-}" ] || {
        printf "candidate evidence tempfile still exists\n" >&2
        return 1
    }
    if [ -n "${PRESERVED_EVIDENCE_DIR:-}" ] && [ -d "$PRESERVED_EVIDENCE_DIR" ]; then
        printf "preserved evidence inputs still existed at cleanup count time\n" >&2
        return 1
    fi
    rm -rf "$RUNTIME_DIR"
    CLEANUP_COUNTS_JSON="{\"algolia_indexes\":0,\"flapjack_indexes\":0,\"algolia_keys\":0,\"local_stack\":0,\"runtime_files\":0}"
}
write_live_evidence() {
    local path
    for path in "$CREATE_HITS_FILE" "$CREATE_PARITY_REPORT" "$CREATE_OUTCOME_FILE" \
        "$OVERWRITE_HITS_FILE" "$OVERWRITE_PARITY_REPORT" "$OVERWRITE_OUTCOME_FILE"; do
        [ -f "$path" ] || return 1
    done
    printf "{\"cleanup\":{\"runtime_files\":99}}\n" > "$1"
}
validate_captured_live_evidence() {
    python3 - "$1" <<'"'"'PY'"'"' || return 1
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert document["cleanup"]["runtime_files"] == 0, document
PY
    [ "$1" = "$2" ] || cp "$1" "$2"
}
run_live_mode "$operator_evidence"
'
    run_probe_function_harness "$body" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "0" \
        "run-live records cleanup counts after evidence inputs are released"
    assert_file_empty_bytes "$err" \
        "run-live cleanup-count ordering harness emits no failure diagnostic"
}

test_capture_outcome_preserves_warnings_and_fails_closed() {
    local tmp helper
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    helper="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py"
    if TMP="$tmp" HELPER="$helper" python3 - <<'PY'
import json
import os
import subprocess
from pathlib import Path

tmp = Path(os.environ["TMP"])
helper = os.environ["HELPER"]


def capture(body):
    out = tmp / "outcome.json"
    result = subprocess.run(
        ["python3", helper, "capture-outcome", json.dumps(body), str(out)],
        capture_output=True,
        text=True,
    )
    return result.returncode, out


benign = [
    {
        "code": "ReadOnlySourceField",
        "message": "Source field is read-only in Flapjack and is not applied during migration.",
        "resource": "Settings",
        "jsonPath": "$.version",
    }
]
rc, out = capture(
    {
        "disposition": "succeeded",
        "terminalAt": "2026-07-26T00:00:00Z",
        "settingsApplied": True,
        "synonymsImported": {"imported": 0},
        "rulesImported": {"imported": 0},
        "warnings": benign,
    }
)
assert rc == 0
assert json.loads(out.read_text(encoding="utf-8")) == {
    "disposition": "succeeded",
    "terminal_at": "2026-07-26T00:00:00Z",
    "settings": True,
    "synonyms": 0,
    "rules": 0,
    "warnings": benign,
}

# A terminal outcome with no warnings key defaults to an empty list, never healthy
# fabrication of a warning array.
rc, out = capture(
    {
        "disposition": "succeeded",
        "terminalAt": "2026-07-26T00:00:00Z",
        "settingsApplied": True,
        "synonymsImported": {"imported": 0},
        "rulesImported": {"imported": 0},
    }
)
assert rc == 0
assert json.loads(out.read_text(encoding="utf-8"))["warnings"] == []

# Fail-closed branches must actually be able to fail.
for broken in (
    {"settingsApplied": True, "synonymsImported": {"imported": 0}, "rulesImported": {"imported": 0}},
    {"disposition": "failed", "terminalAt": "t", "settingsApplied": True, "synonymsImported": {"imported": 0}, "rulesImported": {"imported": 0}},
    {"disposition": "succeeded", "terminalAt": "", "settingsApplied": True, "synonymsImported": {"imported": 0}, "rulesImported": {"imported": 0}},
    {"disposition": "succeeded", "terminalAt": "not-a-timestamp", "settingsApplied": True, "synonymsImported": {"imported": 0}, "rulesImported": {"imported": 0}},
    {"disposition": "succeeded", "terminalAt": "t", "settingsApplied": "yes", "synonymsImported": {"imported": 0}, "rulesImported": {"imported": 0}},
    {"disposition": "succeeded", "terminalAt": "t", "settingsApplied": True, "synonymsImported": {"imported": -1}, "rulesImported": {"imported": 0}},
    {"disposition": "succeeded", "terminalAt": "t", "settingsApplied": True, "synonymsImported": {"imported": 0}, "rulesImported": {"imported": 0}, "warnings": "x"},
):
    rc, _ = capture(broken)
    assert rc == 1, broken
PY
    then
        pass "capture-outcome preserves warnings, defaults empty, and fails closed on bad shapes"
    else
        fail "capture-outcome preserves warnings, defaults empty, and fails closed on bad shapes"
    fi
}

test_live_helper_cli_rejects_wrong_arity_without_partial_output() {
    local tmp helper out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    helper="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py"
    out="$tmp/out.txt"; err="$tmp/err.txt"

    set +e
    python3 "$helper" cleanup-counts 0 0 >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "cleanup-counts rejects partial argument lists"
    assert_file_empty_bytes "$out" "cleanup-counts emits no partial JSON on arity failure"
    assert_file_empty_bytes "$err" "cleanup-counts arity failure emits no traceback"

    set +e
    python3 "$helper" capture-outcome '{}' >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "capture-outcome rejects missing output path"
    assert_file_empty_bytes "$out" "capture-outcome arity failure emits no stdout bytes"
    assert_file_empty_bytes "$err" "capture-outcome arity failure emits no traceback"
}

test_live_evidence_assembly_carries_captured_warnings() {
    local tmp helper classifier
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    helper="$REPO_ROOT/scripts/lib/local_multinode_migration_live.py"
    classifier="$REPO_ROOT/scripts/lib/local_multinode_migration_evidence.py"
    if python3 \
        "$REPO_ROOT/scripts/tests/lib/local_multinode_migration_evidence_assembly_test.py" \
        "$tmp" "$helper" "$classifier"
    then
        pass "live evidence assembly carries captured benign warnings into a PASS verdict"
    else
        fail "live evidence assembly carries captured benign warnings into a PASS verdict"
    fi
}

test_run_live_rejects_fixture_bypass_environment() {
    local tmp stub_dir out err rc log evidence flapjack_dir secret_file fixture
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stub_dir="$tmp/bin"; out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    log="$tmp/live_calls.log"; evidence="$tmp/evidence.json"
    flapjack_dir="$tmp/flapjack"; secret_file="$tmp/.env.secret"
    fixture="$tmp/current_head_evidence.json"
    : > "$log"
    write_fake_flapjack_checkout "$flapjack_dir"
    write_algolia_secret_fixture "$secret_file"
    write_live_stub_bin_dir "$stub_dir" "exit 0"
    FIXTURE_SOURCE="$FIXTURE_DIR/pass_valid_with_ha_overwrite_refusal.json" \
        FIXTURE_DESTINATION="$fixture" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import json
import os
import subprocess
from pathlib import Path

document = json.loads(Path(os.environ["FIXTURE_SOURCE"]).read_text(encoding="utf-8"))
document["repo_sha"] = subprocess.check_output(
    ["git", "-C", os.environ["REPO_ROOT"], "rev-parse", "HEAD"],
    text=True,
).strip()
Path(os.environ["FIXTURE_DESTINATION"]).write_text(
    json.dumps(document), encoding="utf-8"
)
PY

    run_live_probe "$evidence" "$out" "$err" "$rc" \
        LOCAL_MULTINODE_STUB_LOG="$log" PATH="$stub_dir:$PATH" \
        LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1 \
        FLAPJACK_DEV_DIR="$flapjack_dir" FJCLOUD_SECRET_FILE="$secret_file" \
        LOCAL_MULTINODE_MIGRATION_LIVE_CAPTURE_FIXTURE="$fixture"

    assert_eq "$(cat "$rc")" "2" "fixture bypass environment cannot make --run-live pass"
    assert_file_empty_bytes "$out" "fixture bypass rejection emits no PASS status"
    assert_contains "$(cat "$err")" "selected Flapjack identity is invalid" \
        "fixture bypass environment follows the real live preflight path"
    assert_file_empty_bytes "$evidence" \
        "fixture bypass environment does not copy fixture evidence"
    assert_not_contains "$(cat "$log")" "curl called" \
        "fixture bypass rejection fails before live HTTP side effects"
}

test_assert_evidence_rejects_stale_repo_sha() {
    local tmp stale_fixture out err rc current_sha
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stale_fixture="$tmp/stale_sha.json"
    out="$tmp/out.txt"; err="$tmp/err.txt"; rc="$tmp/rc.txt"
    current_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    CURRENT_SHA="$current_sha" \
        FIXTURE_SOURCE="$FIXTURE_DIR/pass_valid_with_ha_overwrite_refusal.json" \
        FIXTURE_DESTINATION="$stale_fixture" \
        python3 - <<'PY'
import json
import os
from pathlib import Path

document = json.loads(Path(os.environ["FIXTURE_SOURCE"]).read_text(encoding="utf-8"))
document["repo_sha"] = "1" * 40
assert document["repo_sha"] != os.environ["CURRENT_SHA"]
Path(os.environ["FIXTURE_DESTINATION"]).write_text(
    json.dumps(document), encoding="utf-8"
)
PY
    PRESERVE_FIXTURE_REPO_SHA=1 run_probe_fixture "$stale_fixture" "$out" "$err" "$rc"

    assert_eq "$(cat "$rc")" "1" "stale repository SHA exits nonzero"
    assert_stdout_exact_status_line "$out" \
        "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=stale_repo_sha" \
        "stale repository SHA emits a stable fail-closed verdict"
    assert_file_empty_bytes "$err" "stale repository SHA emits no diagnostic"
}

test_duplicate_key_guard_is_load_bearing() {
    # Pin the malformed verdict on malformed_duplicate_keys.json to the classifier's
    # reject_duplicate_keys guard specifically: with repo_sha patched to HEAD, the
    # fixture genuinely carries a duplicate top-level key, yet a guard-less parse
    # collapses to the exact byte-for-byte passing document. If the guard were
    # removed the fixture would PASS, so this proves the guard — not incidental
    # missing keys — is what makes the fixture malformed.
    if DUP="$FIXTURE_DIR/malformed_duplicate_keys.json" \
       VALID="$FIXTURE_DIR/pass_valid_known_answer.json" \
       REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import json
import os
import re
import subprocess
from pathlib import Path

head = subprocess.check_output(
    ["git", "-C", os.environ["REPO_ROOT"], "rev-parse", "HEAD"], text=True
).strip()


def patched(path):
    raw = Path(path).read_text(encoding="utf-8")
    return re.sub(
        r'("repo_sha"\s*:\s*")[0-9a-fA-F]{40}(")',
        lambda match: match.group(1) + head + match.group(2),
        raw,
    )


seen = []
json.loads(
    patched(os.environ["DUP"]),
    object_pairs_hook=lambda pairs: (seen.extend(k for k, _ in pairs), dict(pairs))[1],
)
assert seen.count("schema_version") == 2, "fixture must carry a real duplicate key"
assert json.loads(patched(os.environ["DUP"])) == json.loads(patched(os.environ["VALID"]))
PY
    then
        pass "duplicate-key fixture is a passing document plus one duplicate key (guard is load-bearing)"
    else
        fail "duplicate-key fixture is a passing document plus one duplicate key (guard is load-bearing)"
    fi
}

test_probe_keeps_evidence_classifier_in_focused_module() {
    local classifier="$REPO_ROOT/scripts/lib/local_multinode_migration_evidence.py"
    if PROBE_SOURCE="$PROBE" CLASSIFIER_SOURCE="$classifier" python3 - <<'PY'
import os
from pathlib import Path

probe = Path(os.environ["PROBE_SOURCE"])
classifier = Path(os.environ["CLASSIFIER_SOURCE"])
assert len(probe.read_text(encoding="utf-8").splitlines()) <= 800
source = classifier.read_text(encoding="utf-8")
assert "def classify_document(" in source
assert "EXPECTED_BRANCH_DENOMINATOR" in source
assert 'python3 "$EVIDENCE_CLASSIFIER" "$evidence_path"' in probe.read_text(encoding="utf-8")
PY
    then
        pass "probe delegates pure evidence classification to a focused module under 800 lines"
    else
        fail "probe delegates pure evidence classification to a focused module under 800 lines"
    fi
}

test_indeterminate_validates_all_nested_owners() {
    local owner mutation_path
    for owner in node_local_overwrite ha_create_refusal ha_overwrite_refusal cleanup; do
        mutation_path="$(mktemp)"
        register_tmp_path "$mutation_path"
        FIXTURE_SOURCE="$FIXTURE_DIR/fail_indeterminate_result.json" \
            FIXTURE_DESTINATION="$mutation_path" \
            MALFORMED_OWNER="$owner" \
            python3 - <<'PY'
import json
import os

with open(os.environ["FIXTURE_SOURCE"], encoding="utf-8") as source:
    document = json.load(source)

owner = os.environ["MALFORMED_OWNER"]
if owner == "node_local_overwrite":
    document[owner]["response"] = 42
elif owner in {"ha_create_refusal", "ha_overwrite_refusal"}:
    document[owner]["response"] = 42
else:
    document[owner]["algolia_indexes"] = "invalid"

with open(os.environ["FIXTURE_DESTINATION"], "w", encoding="utf-8") as destination:
    json.dump(document, destination)
PY
        assert_probe_file_result "$mutation_path" "indeterminate malformed $owner" \
            "LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=malformed"
    done
}
