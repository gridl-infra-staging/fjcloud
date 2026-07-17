#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."

# shellcheck disable=SC1091
source ops/scripts/lib/rollback_compatibility.sh

TMPDIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

ARTIFACT="$TMPDIR/artifact"
DB_COPY="$TMPDIR/db.snapshot"
MANIFEST="$TMPDIR/manifest.json"
FAKE_BIN="$TMPDIR/bin"
CANDIDATE_STARTED_FILE="$TMPDIR/candidate-started"
PG_COMMAND_LOG="$TMPDIR/postgres-commands.log"
PG_DUMP_CALL_COUNT="$TMPDIR/pg-dump-call-count"
CANDIDATE_PHASE_LOG="$TMPDIR/candidate-phases.log"
CANDIDATE_ACK_LOG="$TMPDIR/candidate-acks.log"
EXPECTED_SHA="0123456789abcdef0123456789abcdef01234567"
MIRROR_SHA="fedcba9876543210fedcba9876543210fedcba98"
mkdir -p "$ARTIFACT" "$FAKE_BIN"
: > "$CANDIDATE_PHASE_LOG"
: > "$CANDIDATE_ACK_LOG"
cat > "$ARTIFACT/fjcloud-api" <<'PY'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import hashlib
import json
import os

host, port = os.environ["LISTEN_ADDR"].rsplit(":", 1)
with open(os.environ["CANDIDATE_STARTED_FILE"], "w", encoding="utf-8") as marker:
    with open(__file__, "rb") as candidate:
        digest = hashlib.sha256(candidate.read()).hexdigest()
    json.dump({"path": os.path.realpath(__file__), "sha256": digest}, marker)

class Handler(BaseHTTPRequestHandler):
    def respond(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/version":
            body = {
                "dev_sha": os.environ["EXPECTED_SHA"],
                "mirror_sha": os.environ["MIRROR_SHA"],
            }
        elif self.path == "/internal/algolia-import/rollback-state":
            body = {
                "rollback_epoch": "migration_aware_required",
                "schema_floor": 56,
                "protocol_floor": 1,
            }
        elif self.path == "/internal/algolia-import/reconcile" and "phase" in request:
            with open(os.environ["CANDIDATE_PHASE_LOG"], "a", encoding="utf-8") as log:
                log.write(request["phase"] + "\n")
            body = {"contract": "algolia_import_reconcile", "phase": request["phase"], "result": "safe"}
        elif self.path == "/internal/algolia-import/ack":
            with open(os.environ["CANDIDATE_ACK_LOG"], "a", encoding="utf-8") as log:
                log.write("ack\n")
            body = {"contract": "algolia_import_ack", "result": "safe"}
        elif self.path == "/internal/algolia-import/jobs/fixture":
            body = {"contract": "algolia_import_get", "result": "safe"}
        elif self.path == "/internal/algolia-import/jobs":
            body = {"contract": "algolia_import_list", "result": "safe"}
        elif self.path == "/internal/algolia-import/scrub":
            body = {"contract": "algolia_import_scrub", "result": "safe"}
        else:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = respond
    do_POST = respond

    def log_message(self, *_):
        pass

HTTPServer((host, int(port)), Handler).serve_forever()
PY
chmod +x "$ARTIFACT/fjcloud-api"
printf 'aggregation-binary\n' > "$ARTIFACT/fjcloud-aggregation-job"
printf 'retention-binary\n' > "$ARTIFACT/fjcloud-retention-job"
printf 'PGDMP fixture archive\n' > "$DB_COPY"

cat > "$FAKE_BIN/postgres_fixture" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "$PG_COMMAND_LOG"
case "$(basename "$0")" in
  initdb)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-D" ]]; then mkdir -p "$2"; break; fi
      shift
    done
    ;;
  pg_dump)
    count=0
    [[ ! -f "$PG_DUMP_CALL_COUNT" ]] || count=$(cat "$PG_DUMP_CALL_COUNT")
    count=$((count + 1))
    printf '%s' "$count" > "$PG_DUMP_CALL_COUNT"
    if [[ "${PG_SCHEMA_MUTATES:-false}" == "true" && $((count % 2)) -eq 0 ]]; then
      printf '%s\n' 'changed fixture schema'
    else
      printf '%s\n' 'stable fixture schema'
    fi
    ;;
esac
SH
chmod +x "$FAKE_BIN/postgres_fixture"
for command in initdb pg_ctl createdb pg_restore pg_dump; do
  ln -s postgres_fixture "$FAKE_BIN/$command"
done
export PATH="$FAKE_BIN:$PATH"
export CANDIDATE_STARTED_FILE EXPECTED_SHA MIRROR_SHA PG_COMMAND_LOG PG_DUMP_CALL_COUNT
export CANDIDATE_PHASE_LOG CANDIDATE_ACK_LOG
export ROLLBACK_FROZEN_LEGACY_SAFE_MIRROR_SHA="$MIRROR_SHA"

API_DIGEST="sha256:$(rollback_file_sha256 "$ARTIFACT/fjcloud-api")"
AGG_DIGEST="sha256:$(rollback_file_sha256 "$ARTIFACT/fjcloud-aggregation-job")"
RETENTION_DIGEST="sha256:$(rollback_file_sha256 "$ARTIFACT/fjcloud-retention-job")"

PORT=$((39000 + $$ % 1000))

write_manifest() {
  local override
  if [[ $# -gt 0 ]]; then
    override="$1"
  else
    override='{}'
  fi
  jq -n \
    --arg expected "$EXPECTED_SHA" \
    --arg mirror "$MIRROR_SHA" \
    --arg api "$API_DIGEST" \
    --arg agg "$AGG_DIGEST" \
    --arg retention "$RETENTION_DIGEST" \
    --argjson now "$(date +%s)" \
    --arg version_url "http://127.0.0.1:$PORT/version" \
    --arg state_url "http://127.0.0.1:$PORT/internal/algolia-import/rollback-state" \
    --arg origin "http://127.0.0.1:$PORT" \
    --argjson protocol_fixtures "$(rollback_protocol_fixtures_json)" \
    --argjson override "$override" \
    '{
      rollback_epoch: "migration_aware_required",
      generated_at_epoch: $now,
      max_manifest_age_seconds: 300,
      schema_floor: 56,
      required_schema_floor: 56,
      protocol_floor: 1,
      required_protocol_floor: 1,
      dev_sha: $expected,
      mirror_sha: $mirror,
      served_version_url: $version_url,
      served_state_url: $state_url,
      features: [
        "algolia_import_get",
        "algolia_import_list",
        "algolia_import_reconcile",
        "algolia_import_ack",
        "algolia_import_scrub"
      ],
      required_features: [
        "algolia_import_get",
        "algolia_import_list",
        "algolia_import_reconcile",
        "algolia_import_ack",
        "algolia_import_scrub"
      ],
      ack_outage_safe: true,
      job_phase_contract: {
        queued: "safe",
        validating_source: "safe",
        copying_configuration: "safe",
        copying_documents: "safe",
        verifying: "safe",
        promoting: "safe",
        cancelling: "safe",
        cancelled: "safe",
        resuming: "safe",
        completed: "safe",
        completed_with_warnings: "safe",
        failed: "safe",
        interrupted: "safe"
      },
      components: {
        "fjcloud-api": {path: "fjcloud-api", sha256: $api},
        "fjcloud-aggregation-job": {path: "fjcloud-aggregation-job", sha256: $agg},
        "fjcloud-retention-job": {path: "fjcloud-retention-job", sha256: $retention}
      },
      protocol_fixtures: [$protocol_fixtures[] | . + {url: ($origin + .path)}]
    } * $override' > "$MANIFEST"
}

assert_ok() {
  local name="$1"
  shift
  local output
  output=$("$@")
  jq -e '.status == "ok"' <<<"$output" >/dev/null || {
    echo "FAIL: $name expected ok, got: $output"
    exit 1
  }
  echo "PASS: $name"
}

assert_fails_with() {
  local name="$1" code="$2"
  shift 2
  local output status
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: $name unexpectedly passed"
    exit 1
  fi
  jq -e --arg code "$code" '.code == $code' <<<"$output" >/dev/null || {
    echo "FAIL: $name expected code $code, got: $output"
    exit 1
  }
  echo "PASS: $name"
}

probe_args=(
  --candidate-artifact "$ARTIFACT"
  --database-copy "$DB_COPY"
  --candidate-manifest "$MANIFEST"
  --expected-served-sha "$EXPECTED_SHA"
)

write_manifest
assert_ok "migration-aware candidate passes complete contract proof" rollback_contract_probe "${probe_args[@]}"
EXPECTED_API_HEX="${API_DIGEST#sha256:}"
jq -e --arg digest "$EXPECTED_API_HEX" \
  '.sha256 == $digest and (.path | endswith("/fjcloud-api"))' \
  "$CANDIDATE_STARTED_FILE" >/dev/null || {
  echo "FAIL: probe did not start the exact artifact-bound candidate"
  exit 1
}
for command in 'pg_restore --list' initdb createdb 'pg_restore --exit-on-error' 'pg_dump --schema-only'; do
  grep -F "$command" "$PG_COMMAND_LOG" >/dev/null || {
    echo "FAIL: probe omitted PostgreSQL isolation step: $command"
    exit 1
  }
done
echo "PASS: probe restores the snapshot into isolated PostgreSQL before starting the exact candidate"
expected_phases='cancelled cancelling completed completed_with_warnings copying_configuration copying_documents failed interrupted promoting queued resuming validating_source verifying'
actual_phases=$(sort -u "$CANDIDATE_PHASE_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
[[ "$actual_phases" == "$expected_phases" ]] || {
  echo "FAIL: runtime proof did not reconcile every persisted job phase"
  exit 1
}
[[ "$(wc -l < "$CANDIDATE_ACK_LOG" | tr -d ' ')" -eq 2 ]] || {
  echo "FAIL: runtime proof did not retry ACK after simulated response loss"
  exit 1
}
echo "PASS: runtime fixtures prove every persisted phase and idempotent ACK retry"
assert_ok "rollback.sh contract-probe branch runs before live handling" bash ops/scripts/rollback.sh --contract-probe "${probe_args[@]}"

write_manifest "{\"rollback_epoch\":\"pre_admission\",\"legacy_safe_mirror_sha\":\"$MIRROR_SHA\"}"
assert_ok "pre-admission uses frozen legacy safe mirror" rollback_contract_probe "${probe_args[@]}"
ROLLBACK_FROZEN_LEGACY_SAFE_MIRROR_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_fails_with "pre-admission rejects a self-asserted legacy mirror" wrong_legacy_safe_mirror \
  rollback_contract_probe "${probe_args[@]}"
ROLLBACK_FROZEN_LEGACY_SAFE_MIRROR_SHA="$MIRROR_SHA"

write_manifest "{\"generated_at_epoch\":1,\"max_manifest_age_seconds\":1}"
assert_fails_with "stale manifest rejected" stale_manifest rollback_contract_probe "${probe_args[@]}"

write_manifest '{"generated_at_epoch":null}'
assert_fails_with "missing manifest freshness rejected" invalid_manifest_freshness rollback_contract_probe "${probe_args[@]}"

write_manifest "{\"generated_at_epoch\":$(( $(date +%s) + 3600 ))}"
assert_fails_with "future-dated manifest rejected" invalid_manifest_freshness rollback_contract_probe "${probe_args[@]}"

printf '%s\n' '[]' > "$MANIFEST"
assert_fails_with "non-object manifest rejected" invalid_manifest rollback_contract_probe "${probe_args[@]}"

assert_fails_with "missing manifest rejected" missing_manifest rollback_contract_probe \
  --candidate-artifact "$ARTIFACT" \
  --database-copy "$DB_COPY" \
  --candidate-manifest "$TMPDIR/missing.json" \
  --expected-served-sha "$EXPECTED_SHA"

write_manifest '{"components":{"fjcloud-api":{"path":"fjcloud-api","sha256":"sha256:wrong"}}}'
assert_fails_with "lying component digest rejected" wrong_component_digest rollback_contract_probe "${probe_args[@]}"

write_manifest '{"components":{"fjcloud-api":null}}'
assert_fails_with "missing component digest rejected" missing_component_digest rollback_contract_probe "${probe_args[@]}"

write_manifest "{\"served_version_url\":\"http://127.0.0.1:$PORT/version\"}"
assert_fails_with "wrong expected dev SHA rejected" wrong_dev_sha rollback_contract_probe \
  --candidate-artifact "$ARTIFACT" \
  --database-copy "$DB_COPY" \
  --candidate-manifest "$MANIFEST" \
  --expected-served-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

write_manifest '{"mirror_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
assert_fails_with "wrong mirror SHA rejected" wrong_mirror_sha rollback_contract_probe "${probe_args[@]}"

write_manifest '{"schema_floor":55}'
assert_fails_with "low schema floor rejected" schema_floor_too_low rollback_contract_probe "${probe_args[@]}"

write_manifest '{"protocol_floor":0}'
assert_fails_with "low protocol floor rejected" protocol_floor_too_low rollback_contract_probe "${probe_args[@]}"

write_manifest '{"features":["algolia_import_get"]}'
assert_fails_with "missing protocol feature rejected" missing_protocol_feature rollback_contract_probe "${probe_args[@]}"

write_manifest '{"required_features":["algolia_import_get"],"features":["algolia_import_get"],"protocol_fixtures":[{"feature":"algolia_import_get","method":"GET","url":"http://127.0.0.1:'"$PORT"'/jobs/example","expected_status":200,"expected_body":{"fixture":"/jobs/example","safe":true}}]}'
assert_fails_with "manifest cannot weaken canonical protocol features" missing_protocol_feature rollback_contract_probe "${probe_args[@]}"

write_manifest
jq \
  --arg url "http://127.0.0.1:$PORT/version" \
  --arg dev "$EXPECTED_SHA" \
  --arg mirror "$MIRROR_SHA" \
  '.protocol_fixtures |= map(.path = "/version" | .url = $url | .expected_body = {dev_sha: $dev, mirror_sha: $mirror})' \
  "$MANIFEST" > "$TMPDIR/lying-fixtures.json"
mv "$TMPDIR/lying-fixtures.json" "$MANIFEST"
assert_fails_with "manifest cannot choose its own known answers" invalid_protocol_fixture rollback_contract_probe "${probe_args[@]}"

write_manifest '{"job_phase_contract":{"interrupted":"unsafe"}}'
assert_fails_with "missing persisted job phase proof rejected" missing_job_phase_contract rollback_contract_probe "${probe_args[@]}"

write_manifest '{"ack_outage_safe":false}'
assert_fails_with "ACK outage without proof rejected" ack_outage_unproven rollback_contract_probe "${probe_args[@]}"

write_manifest '{"served_version_url":"http://10.0.0.2/version"}'
assert_fails_with "non-loopback candidate refused" non_loopback_candidate rollback_contract_probe "${probe_args[@]}"

write_manifest "{\"served_state_url\":\"http://127.0.0.1:$PORT/version\"}"
assert_fails_with "wrong served state rejected" wrong_served_state rollback_contract_probe "${probe_args[@]}"

write_manifest
rm -f "$PG_DUMP_CALL_COUNT"
export PG_SCHEMA_MUTATES=true
assert_fails_with "schema open mutation rejected" schema_mutated_snapshot rollback_contract_probe "${probe_args[@]}"
unset PG_SCHEMA_MUTATES

write_manifest
first=$(rollback_contract_probe "${probe_args[@]}")
second=$(rollback_contract_probe "${probe_args[@]}")
if [[ "$(jq -r '.code' <<<"$first")" != "$(jq -r '.code' <<<"$second")" ]]; then
  echo "FAIL: rollback-process restart changed proof result"
  exit 1
fi
echo "PASS: rollback-process restart preserves proof result"

mutation_decision=$(rollback_contract_probe "${probe_args[@]}")
proof_decision=$(rollback_contract_probe "${probe_args[@]}")
if [[ "$mutation_decision" != "$proof_decision" ]]; then
  echo "FAIL: proof/mutation decision parity drifted"
  exit 1
fi
echo "PASS: proof/mutation decision parity"

AWS() { echo "FAIL: standalone probe attempted AWS"; exit 1; }
aws() { echo "FAIL: standalone probe attempted aws"; exit 1; }
export -f AWS aws
assert_ok "standalone probe makes zero AWS calls" rollback_contract_probe "${probe_args[@]}"

FAKE_AWS_CAPTURE="$TMPDIR/ssm-parameters.json"
cat > "$FAKE_BIN/aws" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
service="${1:-}"
operation="${2:-}"
case "$service:$operation" in
  ec2:describe-instances) printf '%s\n' 'i-fixture' ;;
  ssm:get-parameter) printf '%s\n' "$MIRROR_SHA" ;;
  ssm:send-command)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--parameters" ]]; then printf '%s' "$2" > "$FAKE_AWS_CAPTURE"; break; fi
      shift
    done
    printf '%s\n' 'command-fixture'
    ;;
  ssm:get-command-invocation) printf '%s\n' 'Success' ;;
  ssm:put-parameter) ;;
  *) echo "unexpected fake aws call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$FAKE_BIN/aws"
export FAKE_AWS_CAPTURE
unset -f AWS aws
bash ops/scripts/rollback.sh staging "$MIRROR_SHA" >/dev/null
INSTANCE_SCRIPT_CAPTURED="$TMPDIR/instance-script.sh"
jq -r '.commands[]' "$FAKE_AWS_CAPTURE" > "$INSTANCE_SCRIPT_CAPTURED"
for required in 'rollback_contract.json' '/usr/local/lib/fjcloud/rollback_compatibility.sh' 'ROLLBACK_LIBRARY_SHA256' 'dnf install -y postgresql16-server' 'pg_dump --format=custom' 'rollback_contract_probe' 'migration_aware_required' 'pre_admission' 'LEGACY_SAFE_MIRROR_SHA' '[[ "$SHA" == "$LEGACY_SAFE_MIRROR_SHA" ]]' 'mv "${CANDIDATE_DIR}/${bin}" "${BIN_DIR}/${bin}"'; do
  grep -F "$required" "$INSTANCE_SCRIPT_CAPTURED" >/dev/null || {
    echo "FAIL: live rollback omitted required pre-swap proof step: $required"
    exit 1
  }
done
if grep -F 'ROLLBACK_LIBRARY_B64' "$INSTANCE_SCRIPT_CAPTURED" >/dev/null; then
  echo "FAIL: live rollback embeds the proof library in the bounded SSM payload"
  exit 1
fi
grep -F 'runuser -u "${ROLLBACK_PROOF_USER:-fjcloud}" -- env' ops/scripts/lib/rollback_compatibility.sh >/dev/null || {
  echo "FAIL: live rollback proof does not run the candidate as the service user"
  exit 1
}
probe_line=$(grep -n 'rollback_contract_probe' "$INSTANCE_SCRIPT_CAPTURED" | tail -1 | cut -d: -f1)
swap_line=$(grep -n 'mv "${CANDIDATE_DIR}/${bin}" "${BIN_DIR}/${bin}"' "$INSTANCE_SCRIPT_CAPTURED" | cut -d: -f1)
if (( probe_line >= swap_line )); then
  echo "FAIL: live rollback swaps binaries before compatibility proof"
  exit 1
fi
echo "PASS: live rollback materializes and proves the unswapped candidate before mutation"

grep -F 'postgresql16-server' ops/packer/flapjack-ami.pkr.hcl >/dev/null || {
  echo "FAIL: rollback proof PostgreSQL server tools are not baked into the AMI"
  exit 1
}
grep -F 'postgresql16-server' ops/terraform/compute/main.tf >/dev/null || {
  echo "FAIL: rollback proof PostgreSQL server tools are not present in host bootstrap"
  exit 1
}
echo "PASS: host bootstrap owns isolated PostgreSQL proof dependencies"

GENERATED_MANIFEST="$TMPDIR/generated-rollback-contract.json"
rollback_write_release_manifest \
  "$GENERATED_MANIFEST" \
  "$EXPECTED_SHA" \
  "$MIRROR_SHA" \
  "$ARTIFACT"
jq -e \
  --arg api "$API_DIGEST" \
  --arg mirror "$MIRROR_SHA" \
  '.mirror_sha == $mirror and .legacy_safe_mirror_sha == null and .components["fjcloud-api"].sha256 == $api and (.features | length) == 5' \
  "$GENERATED_MANIFEST" >/dev/null || {
  echo "FAIL: generated release contract does not bind identity, components, and canonical features"
  exit 1
}
grep -F 'job_phase_contract: (reduce $phases[] as $phase ({}; .[$phase] = "safe"))' \
  ops/scripts/lib/rollback_compatibility.sh >/dev/null || {
  echo "FAIL: release manifest jq must parenthesize reduce expressions for staging jq compatibility"
  exit 1
}
echo "PASS: shared owner generates immutable release contract contents"

grep -F 'SSM_LEGACY_SAFE_SHA="/fjcloud/${ENV}/algolia_import_legacy_safe_mirror_sha"' ops/scripts/deploy.sh >/dev/null || {
  echo "FAIL: deploy does not own the environment-scoped frozen legacy mirror"
  exit 1
}
grep -F 'aws ssm put-parameter' ops/scripts/deploy.sh >/dev/null || {
  echo "FAIL: deploy does not initialize the frozen legacy mirror"
  exit 1
}
echo "PASS: deploy initializes one environment-scoped frozen legacy mirror"
grep -F 'scripts/lib/rollback_compatibility.sh' ops/scripts/deploy.sh >/dev/null || {
  echo "FAIL: deploy does not install the release-published rollback gate"
  exit 1
}
echo "PASS: deploy installs the shared rollback gate on the API host"

workflow_manifest_uploads=$(grep -c 'rollback_contract.json s3://fjcloud-releases-' .github/workflows/ci.yml || true)
if [[ "$workflow_manifest_uploads" -ne 2 ]]; then
  echo "FAIL: staging and production releases must both publish rollback_contract.json"
  exit 1
fi
workflow_manifest_generators=$(grep -c 'rollback_write_release_manifest' .github/workflows/ci.yml || true)
if [[ "$workflow_manifest_generators" -ne 2 ]]; then
  echo "FAIL: staging and production releases must generate contracts through the shared owner"
  exit 1
fi
workflow_gate_uploads=$(grep -c 'rollback_compatibility.sh s3://fjcloud-releases-' .github/workflows/ci.yml || true)
if [[ "$workflow_gate_uploads" -ne 2 ]]; then
  echo "FAIL: staging and production releases must both publish rollback_compatibility.sh"
  exit 1
fi
echo "PASS: release publication emits the immutable rollback contract for both environments"
