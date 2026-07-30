#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/update_algolia_migration_engine_contract.sh"
FIXTURE="$REPO_ROOT/infra/api/tests/fixtures/algolia_migration_engine_contract.json"

tmpdir="$(mktemp -d)"
fixture_tmpdir="$(mktemp -d "$REPO_ROOT/infra/api/tests/fixtures/.tmp.update_algolia_contract.XXXXXX")"
trap 'rm -rf "$tmpdir" "$fixture_tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

write_openapi() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<'JSON'
{
  "openapi": "3.1.0",
  "paths": {
    "/1/migrations/algolia": {
      "post": {
        "requestBody": {
          "content": {
            "application/json": {
              "schema": {"$ref": "#/components/schemas/MigrateFromAlgoliaRequest"}
            }
          }
        },
        "responses": {
          "202": {"description": "Accepted"},
          "503": {
            "description": "Migration temporarily unavailable",
            "content": {"application/json": {"examples": {
              "migration_ha_unsupported": {"value": {"code": "migration_ha_unsupported"}},
              "migration_capacity_exhausted": {"value": {"code": "migration_capacity_exhausted"}}
            }}}
          }
        }
      }
    },
    "/1/migrations/algolia/{job_id}": {
      "get": {
        "responses": {
          "200": {"description": "OK"},
          "404": {
            "description": "Not found",
            "content": {"application/json": {"examples": {
              "migration_job_not_found": {"value": {"code": "migration_job_not_found"}}
            }}}
          }
        }
      }
    },
    "/1/migrations/algolia/{job_id}/cancel": {
      "post": {
        "responses": {
          "200": {"description": "OK"},
          "404": {
            "description": "Not found",
            "content": {"application/json": {"examples": {
              "migration_job_not_found": {"value": {"code": "migration_job_not_found"}}
            }}}
          },
          "409": {
            "description": "Too late",
            "content": {"application/json": {"examples": {
              "cancel_too_late": {"value": {"code": "cancel_too_late"}}
            }}}
          }
        }
      }
    },
    "/1/migrations/algolia/{job_id}/acknowledge": {
      "post": {
        "operationId": "acknowledge_algolia_migration",
        "security": [{"api_key": []}],
        "parameters": [
          {
            "name": "job_id",
            "in": "path",
            "required": true,
            "schema": {"type": "string", "format": "uuid"}
          }
        ],
        "responses": {
          "204": {"description": "Terminal migration acknowledged"},
          "400": {"description": "Invalid migration job UUID"},
          "404": {"description": "No durable migration phase record is currently retained for the UUID"},
          "409": {"description": "migration_ack_too_early"},
          "500": {"description": "Migration status record could not be read"}
        },
        "requestBody": null
      }
    },
    "/1/migrations/privacy-scrub": {
      "post": {
        "operationId": "submit_privacy_scrub",
        "security": [{"private_migration": []}],
        "requestBody": {
          "content": {
            "application/json": {
              "schema": {"$ref": "#/components/schemas/PrivacyScrubRequest"}
            }
          },
          "required": true
        },
        "responses": {
          "202": {
            "description": "Privacy scrub exact-absence ACK",
            "content": {
              "application/json": {
                "schema": {"$ref": "#/components/schemas/PrivacyScrubAck"}
              }
            }
          },
          "400": {"description": "Invalid privacy scrub request"},
          "403": {"description": "Private migration credential required"},
          "409": {"description": "Privacy scrub refused or retryable"}
        }
      }
    }
  },
  "components": {
    "schemas": {
      "MigrateFromAlgoliaRequest": {
        "type": "object",
        "required": ["appId", "apiKey", "sourceIndex"],
        "properties": {
          "appId": {"type": "string"},
          "apiKey": {"type": "string"},
          "sourceIndex": {"type": "string"},
          "targetIndex": {"type": "string"},
          "overwrite": {"type": "boolean", "default": false}
        }
      },
      "AsyncMigrationStatusResponse": {
        "type": "object",
        "required": ["jobId", "phase", "disposition", "createdAt", "updatedAt"],
        "properties": {
          "jobId": {"type": "string"},
          "phase": {"$ref": "#/components/schemas/AsyncMigrationPhase"},
          "disposition": {"$ref": "#/components/schemas/AsyncMigrationDisposition"},
          "createdAt": {"type": "string"},
          "updatedAt": {"type": "string"},
          "exportProgress": {"$ref": "#/components/schemas/AsyncMigrationExportProgress"},
          "terminalAt": {"type": "string"},
          "settingsApplied": {"type": ["boolean", "null"]},
          "synonymsImported": {
            "oneOf": [
              {"type": "null"},
              {"$ref": "#/components/schemas/MigrateCount"}
            ]
          },
          "rulesImported": {
            "oneOf": [
              {"type": "null"},
              {"$ref": "#/components/schemas/MigrateCount"}
            ]
          },
          "warnings": {
            "type": "array",
            "items": {"$ref": "#/components/schemas/MigrateWarning"}
          }
        }
      },
      "MigrateCount": {
        "type": "object",
        "required": ["imported"],
        "properties": {
          "imported": {"type": "integer", "minimum": 0}
        }
      },
      "MigrateWarning": {
        "type": "object",
        "required": ["code", "message", "resource", "jsonPath"],
        "properties": {
          "code": {"type": "string"},
          "message": {"type": "string"},
          "resource": {"type": "string"},
          "pageIndex": {"type": ["integer", "null"], "minimum": 0},
          "itemIndex": {"type": ["integer", "null"], "minimum": 0},
          "jsonPath": {"type": "string"}
        }
      },
      "AsyncMigrationExportProgress": {
        "type": "object",
        "required": ["completed", "total"],
        "properties": {
          "completed": {"type": "integer"},
          "total": {"type": "integer"}
        }
      },
      "AsyncMigrationPhase": {
        "type": "string",
        "enum": ["submitted", "exporting", "preparing", "staging", "activating"]
      },
      "AsyncMigrationDisposition": {
        "type": "string",
        "enum": ["running", "succeeded", "failed", "cancelled"]
      },
      "PrivacyScrubRequest": {
        "type": "object",
        "required": ["expectedGeneration", "scrubId", "tenant"],
        "properties": {
          "expectedGeneration": {"type": "string"},
          "objectIDs": {"type": "array", "items": {"type": "string"}},
          "ruleIDs": {"type": "array", "items": {"type": "string"}},
          "scrubId": {"type": "string"},
          "synonymIDs": {"type": "array", "items": {"type": "string"}},
          "tenant": {"type": "string"}
        }
      },
      "PrivacyScrubAck": {
        "type": "object",
        "required": ["scrubId", "disposition"],
        "properties": {
          "disposition": {"type": "string"},
          "scrubId": {"type": "string"}
        }
      }
    }
  }
}
JSON
}

init_engine_repo() {
    local dir="$1"
    mkdir -p "$dir/engine/docs2/4_EVIDENCE" "$dir/engine/tests" "$dir/scripts"
    cat >"$dir/engine/Cargo.toml" <<'EOF_CARGO'
[package]
name = "flapjack-server"
version = "0.0.0"
EOF_CARGO
    cat >"$dir/scripts/update_algolia_migration_engine_contract.sh" <<'EOF_PRIVACY_CHECK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "--check" ]; then
    exit 2
fi
printf '%s\n' 'privacy-scrub transport receipt: PASS'
EOF_PRIVACY_CHECK
    chmod +x "$dir/scripts/update_algolia_migration_engine_contract.sh"
    cat >"$dir/engine/tests/migration_import_contract_test.sh" <<'EOF_ACK_TEST'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '  [PASS] privacy scrub transport receipt validates the reviewed merge baseline'
printf '%s\n' 'Results: 999/999 passed (0 skipped)'
EOF_ACK_TEST
    chmod +x "$dir/engine/tests/migration_import_contract_test.sh"
    cat >"$dir/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json" <<'EOF_RECEIPT'
{
  "receipt_type": "privacy_scrub_transport",
  "validated_head_sha": "c14fd322842c42cf2527616a69f708257194a9ef",
  "scrub_implementation_sha": "674f243579e2f31ce15a00c8f79d8a98842c7659",
  "denominators": {
    "boundary_variants": {
      "count": 7,
      "variants": [
        "PreIntent",
        "PostIntent",
        "EngineCommit",
        "PreAck",
        "ResponseLoss",
        "Restart",
        "AckReplay"
      ]
    },
    "auth_negative_cases": {
      "count": 4,
      "cases": [
        "missing credentials",
        "wrong credentials",
        "incomplete app material",
        "ordinary admin credentials"
      ]
    },
    "replay_assertions": {
      "count": 2,
      "sources": [
        "engine/flapjack-http/src/handlers/migration/import_contract_tests.rs::privacy_scrub_durability_ack_is_idempotent_after_exact_absence",
        "engine/flapjack-http/src/handlers/migration/import_contract_recovery_tests.rs::privacy_scrub_recovery_replays_ack_after_response_loss_and_restart"
      ]
    },
    "exact_absence_resource_classes": {
      "count": 3,
      "classes": [
        "objectIDs",
        "synonymIDs",
        "ruleIDs"
      ]
    }
  },
  "validation_commands": {
    "default_privacy_scrub": {"command": "cargo test privacy_scrub", "exit_code": 0, "result": "13 passed"},
    "default_generation_evidence": {"command": "cargo test privacy_scrub_generation_evidence", "exit_code": 0, "result": "1 passed"},
    "default_openapi": {"command": "cargo test openapi_export_tests", "exit_code": 0, "result": "8 passed"},
    "vector_privacy_scrub": {"command": "cargo test --features vector-search privacy_scrub", "exit_code": 0, "result": "13 passed"},
    "vector_generation_evidence": {"command": "cargo test --features vector-search privacy_scrub_generation_evidence", "exit_code": 0, "result": "1 passed"},
    "neighbor_ha_admission": {"command": "cargo test async_import_ha_state_is_refused_by_shared_admission_owner", "exit_code": 0, "result": "1 passed"},
    "neighbor_cancel_publication": {"command": "cargo test async_import_cancel_after_export_acceptance_settles_cancelled_and_publishes_no_target", "exit_code": 0, "result": "1 passed"},
    "neighbor_terminal_recovery": {"command": "cargo test async_recovery_leaves_terminal_jobs_untouched", "exit_code": 0, "result": "1 passed"},
    "neighbor_mutation_fence": {"command": "cargo test mutation_fence", "exit_code": 0, "result": "6 passed"},
    "migration_contract_suite": {"command": "bash tests/migration_import_contract_test.sh", "exit_code": 0, "result": "154/154 passed"},
    "fmt_check": {"command": "cargo fmt --check", "exit_code": 0, "result": "clean"},
    "clippy": {"command": "cargo clippy --all-targets -- -D warnings", "exit_code": 0, "result": "clean"}
  }
}
EOF_RECEIPT
    write_openapi "$dir/engine/docs2/openapi.json"
    mkdir -p "$dir/engine/demo-dualclient/public"
    cp "$dir/engine/docs2/openapi.json" "$dir/engine/demo-dualclient/public/openapi.json"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Contract Test"
    git -C "$dir" add .
    git -C "$dir" commit -q -m "fixture engine"
}

run_checker() {
    local engine_dir="$1"
    local expected_sha="$2"
    local fixture_path="$3"
    shift 3
    FLAPJACK_DEV_DIR="$engine_dir" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_ACK_SEMANTIC_CHECK="$tmpdir/ack-semantic-check" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_PINNED_SHA_FOR_TEST="$expected_sha" \
        "$CHECKER" --check --fixture "$fixture_path" "$@"
}

run_updater() {
    local engine_dir="$1"
    local expected_sha="$2"
    local fixture_path="$3"
    shift 3
    FLAPJACK_DEV_DIR="$engine_dir" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_ACK_SEMANTIC_CHECK="$tmpdir/ack-semantic-check" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_PINNED_SHA_FOR_TEST="$expected_sha" \
        "$CHECKER" --update --fixture "$fixture_path" "$@"
}

assert_action_required() {
    local output="$1"
    grep -q 'ACTION_REQUIRED' "$output" || {
        cat "$output" >&2
        fail "expected ACTION_REQUIRED diagnostic"
    }
    if grep -q 'Traceback' "$output"; then
        cat "$output" >&2
        fail "ACTION_REQUIRED failure must not expose a Python traceback"
    fi
}

assert_fails_action_required() {
    local output="$tmpdir/output.$RANDOM"
    if "$@" >"$output" 2>&1; then
        cat "$output" >&2
        fail "expected command to fail"
    fi
    assert_action_required "$output"
}

assert_fails_with_status() {
    local expected_status="$1"
    local output="$tmpdir/output.$RANDOM"
    shift
    local actual_status=0
    "$@" >"$output" 2>&1 || actual_status=$?
    [ "$actual_status" -eq "$expected_status" ] || {
        cat "$output" >&2
        fail "expected exit $expected_status, got $actual_status"
    }
    assert_action_required "$output"
}

mutate_openapi_artifacts() {
    local fixture_path="$1"
    local scope="$2"
    local mutation="$3"
    python3 - "$engine" "$fixture_path" "$scope" "$mutation" <<'PY'
import hashlib
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
scope = sys.argv[3]
mutation = sys.argv[4]
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
for index, artifact in enumerate(fixture["openapi_artifacts"]):
    if scope == "first" and index != 0:
        continue
    if scope == "second" and index != 1:
        continue
    path = engine / artifact["path"]
    payload = json.loads(path.read_text(encoding="utf-8"))
    exec(mutation, {"json": json}, {"payload": payload})
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
}

widen_openapi_provider_aliases() {
    python3 - "$engine" <<'PY'
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
for rel_path in [
    "engine/docs2/openapi.json",
    "engine/demo-dualclient/public/openapi.json",
]:
    path = engine / rel_path
    payload = json.loads(path.read_text(encoding="utf-8"))
    paths = payload["paths"]
    algolia_aliases = {
        key: value
        for key, value in paths.items()
        if key.startswith("/1/migrations/algolia")
    }
    for provider in ["meilisearch", "typesense"]:
        for algolia_path, operation in algolia_aliases.items():
            paths[algolia_path.replace("/algolia", f"/{provider}", 1)] = operation
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
    git -C "$engine" add engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
    git -C "$engine" commit -q -m "publish provider aliases"
}

add_status_contract_fields() {
    python3 - "$engine" <<'PY'
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
for rel_path in [
    "engine/docs2/openapi.json",
    "engine/demo-dualclient/public/openapi.json",
]:
    path = engine / rel_path
    payload = json.loads(path.read_text(encoding="utf-8"))
    schemas = payload["components"]["schemas"]
    schemas["MigrationTopology"] = {
        "type": "string",
        "enum": ["single_node_only"],
    }
    status_properties = schemas["AsyncMigrationStatusResponse"]["properties"]
    status_properties["objectsImported"] = {
        "oneOf": [
            {"type": "null"},
            {"$ref": "#/components/schemas/MigrateCount"},
        ],
    }
    status_properties["targetIndex"] = {"type": ["string", "null"]}
    status_properties["topology"] = {
        "oneOf": [
            {"type": "null"},
            {"$ref": "#/components/schemas/MigrationTopology"},
        ],
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
    git -C "$engine" add engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
    git -C "$engine" commit -q -m "publish status schema fields"
}

snapshot_paths() {
    python3 - "$@" <<'PY'
import hashlib
import pathlib
import stat
import sys

for raw_path in sys.argv[1:]:
    root = pathlib.Path(raw_path)
    paths = [root]
    if root.is_dir():
        paths.extend(
            path for path in root.rglob("*")
            if ".git" not in path.relative_to(root).parts
        )
    for path in sorted(paths):
        relative = "." if path == root else path.relative_to(root).as_posix()
        metadata = path.lstat()
        kind = "directory" if path.is_dir() else "symlink" if path.is_symlink() else "file"
        digest = ""
        if path.is_file() and not path.is_symlink():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_symlink():
            digest = hashlib.sha256(path.readlink().as_posix().encode()).hexdigest()
        print(raw_path, relative, kind, stat.S_IMODE(metadata.st_mode), digest)
PY
}

engine="$tmpdir/flapjack"
init_engine_repo "$engine"
cat >"$tmpdir/ack-semantic-check" <<'EOF_ACK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-missing-engine-root}" >>"${ACK_CHECK_LOG:?}"
[ "${ACK_CHECK_SCENARIO:-pass}" = "pass" ]
EOF_ACK
chmod +x "$tmpdir/ack-semantic-check"
export ACK_CHECK_LOG="$tmpdir/ack-semantic-check.log"
validated_head_sha="$(git -C "$engine" rev-parse HEAD)"
python3 - "$engine/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json" \
    "$validated_head_sha" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["validated_head_sha"] = sys.argv[2]
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
git -C "$engine" add engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json
git -C "$engine" commit -q -m "fixture receipt"
head_sha="$(git -C "$engine" rev-parse HEAD)"
artifact_sha="$(shasum -a 256 "$engine/engine/docs2/openapi.json" | awk '{print $1}')"
test_fixture="$fixture_tmpdir/contract.json"
cp "$FIXTURE" "$test_fixture"
python3 - "$test_fixture" "$head_sha" "$artifact_sha" "$validated_head_sha" <<'PY'
import json
import sys

path, head_sha, artifact_sha, validated_head_sha = sys.argv[1:5]
payload = json.loads(open(path, encoding="utf-8").read())
payload["pinned_engine_sha"] = head_sha
payload["privacy_scrub_contract"]["receipt"]["validated_head_sha"] = validated_head_sha
payload["provider_discriminator"] = {
    "field": "source_provider",
    "values": ["algolia"],
}
payload["provider_aliases"] = {
    "algolia": {
        "acknowledge": "/1/migrations/algolia/{job_id}/acknowledge",
        "cancel": "/1/migrations/algolia/{job_id}/cancel",
        "status": "/1/migrations/algolia/{job_id}",
        "submit": "/1/migrations/algolia",
    },
}
payload["status"]["optional_fields"] = [
    "exportProgress",
    "rulesImported",
    "settingsApplied",
    "synonymsImported",
    "terminalAt",
    "warnings",
]
for artifact in payload["openapi_artifacts"]:
    artifact["sha256"] = artifact_sha
open(path, "w", encoding="utf-8").write(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY

snapshot_paths "$engine" "$CHECKER" "$test_fixture" "$FIXTURE" >"$tmpdir/read_only.before"

run_checker "$engine" "$head_sha" "$test_fixture"
grep -q '/engine$' "$ACK_CHECK_LOG" || fail "ACK semantic check should receive an engine path"

snapshot_paths "$engine" "$CHECKER" "$test_fixture" "$FIXTURE" >"$tmpdir/read_only.after"
cmp -s "$tmpdir/read_only.before" "$tmpdir/read_only.after" || {
    diff -u "$tmpdir/read_only.before" "$tmpdir/read_only.after" >&2 || true
    fail "--check modified an engine or contract input"
}

outside_fixture="$tmpdir/contract.outside-fixtures.json"
cp "$test_fixture" "$outside_fixture"
assert_fails_action_required run_checker "$engine" "$head_sha" "$outside_fixture"

update_fixture="$fixture_tmpdir/contract.update.json"
cp "$test_fixture" "$update_fixture"
python3 - "$update_fixture" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.loads(open(path, encoding="utf-8").read())
payload["pinned_engine_sha"] = "0" * 40
for artifact in payload["openapi_artifacts"]:
    artifact["sha256"] = "0" * 64
open(path, "w", encoding="utf-8").write(json.dumps(payload, indent=2) + "\n")
PY
cp "$update_fixture" "$tmpdir/contract.update.before.json"
run_updater "$engine" "$head_sha" "$update_fixture"
python3 - "$tmpdir/contract.update.before.json" "$update_fixture" "$engine" "$head_sha" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

before_path, after_path, engine_root, head_sha = sys.argv[1:5]
before = json.loads(open(before_path, encoding="utf-8").read())
after = json.loads(open(after_path, encoding="utf-8").read())
expected = copy.deepcopy(before)
expected["pinned_engine_sha"] = head_sha
for artifact in expected["openapi_artifacts"]:
    artifact_path = pathlib.Path(engine_root) / artifact["path"]
    artifact["sha256"] = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
if after != expected:
    raise SystemExit("update changed fields outside pinned_engine_sha/openapi_artifacts sha256")
PY

provider_update_fixture="$fixture_tmpdir/contract.provider-update.json"
cp "$test_fixture" "$provider_update_fixture"
widen_openapi_provider_aliases
provider_head_sha="$(git -C "$engine" rev-parse HEAD)"
cp "$provider_update_fixture" "$tmpdir/contract.provider-update.before.json"
run_updater "$engine" "$provider_head_sha" "$provider_update_fixture"
python3 - "$tmpdir/contract.provider-update.before.json" "$provider_update_fixture" "$provider_head_sha" <<'PY'
import copy
import json
import sys

before_path, after_path, provider_head_sha = sys.argv[1:4]
before = json.loads(open(before_path, encoding="utf-8").read())
after = json.loads(open(after_path, encoding="utf-8").read())
expected_providers = ["algolia", "meilisearch", "typesense"]
expected_aliases = {
    provider: {
        "submit": f"/1/migrations/{provider}",
        "status": f"/1/migrations/{provider}/{{job_id}}",
        "cancel": f"/1/migrations/{provider}/{{job_id}}/cancel",
        "acknowledge": f"/1/migrations/{provider}/{{job_id}}/acknowledge",
    }
    for provider in expected_providers
}
if after["pinned_engine_sha"] != provider_head_sha:
    raise SystemExit("provider update did not pin the widened engine commit")
if after["provider_discriminator"] != {
    "field": "source_provider",
    "values": expected_providers,
}:
    raise SystemExit("provider update did not widen provider_discriminator")
if after["provider_aliases"] != expected_aliases:
    raise SystemExit("provider update did not widen provider_aliases")
if after["routes"] != before["routes"]:
    raise SystemExit("provider update changed shared lifecycle routes")
normalized_before = copy.deepcopy(before)
normalized_after = copy.deepcopy(after)
for payload in [normalized_before, normalized_after]:
    payload["pinned_engine_sha"] = "<normalized>"
    payload["provider_discriminator"] = "<normalized>"
    payload["provider_aliases"] = "<normalized>"
    for artifact in payload["openapi_artifacts"]:
        artifact["sha256"] = "<normalized>"
if normalized_after != normalized_before:
    raise SystemExit("provider update changed non-provider contract keys")
PY

status_update_fixture="$fixture_tmpdir/contract.status-update.json"
cp "$provider_update_fixture" "$status_update_fixture"
add_status_contract_fields
status_head_sha="$(git -C "$engine" rev-parse HEAD)"
cp "$status_update_fixture" "$tmpdir/contract.status-update.before.json"
run_updater "$engine" "$status_head_sha" "$status_update_fixture"
python3 - "$tmpdir/contract.status-update.before.json" "$status_update_fixture" "$engine" "$status_head_sha" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

before_path, after_path, engine_root, status_head_sha = sys.argv[1:5]
before = json.loads(open(before_path, encoding="utf-8").read())
after = json.loads(open(after_path, encoding="utf-8").read())
expected_optional = [
    "exportProgress",
    "objectsImported",
    "rulesImported",
    "settingsApplied",
    "synonymsImported",
    "targetIndex",
    "terminalAt",
    "topology",
    "warnings",
]
if after["pinned_engine_sha"] != status_head_sha:
    raise SystemExit("status update did not pin the widened status commit")
if after["status"]["required_fields"] != before["status"]["required_fields"]:
    raise SystemExit("status update changed required status fields")
if after["status"]["optional_fields"] != expected_optional:
    raise SystemExit("status update did not accept exactly the additive status fields")

normalized_before = copy.deepcopy(before)
normalized_after = copy.deepcopy(after)
for payload in [normalized_before, normalized_after]:
    payload["pinned_engine_sha"] = "<normalized>"
    payload["status"] = "<normalized>"
    for artifact in payload["openapi_artifacts"]:
        artifact["sha256"] = "<normalized>"
if normalized_after != normalized_before:
    raise SystemExit("status update changed non-status contract keys")

expected = copy.deepcopy(before)
expected["pinned_engine_sha"] = status_head_sha
expected["status"] = after["status"]
for artifact in expected["openapi_artifacts"]:
    artifact_path = pathlib.Path(engine_root) / artifact["path"]
    artifact["sha256"] = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
if after != expected:
    raise SystemExit("status update changed fields outside pinned_engine_sha/openapi_artifacts/status")
PY

status_check_drift_fixture="$fixture_tmpdir/contract.status-check-drift.json"
cp "$status_update_fixture" "$status_check_drift_fixture"
python3 - "$status_check_drift_fixture" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["status"]["optional_fields"] = [
    field
    for field in payload["status"]["optional_fields"]
    if field not in {"objectsImported", "targetIndex", "topology"}
]
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required \
    run_checker "$engine" "$status_head_sha" "$status_check_drift_fixture"

provider_check_drift_fixture="$fixture_tmpdir/contract.provider-check-drift.json"
cp "$provider_update_fixture" "$provider_check_drift_fixture"
python3 - "$provider_check_drift_fixture" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["provider_discriminator"]["values"] = ["algolia"]
payload["provider_aliases"] = {
    "algolia": payload["provider_aliases"]["algolia"],
}
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required \
    run_checker "$engine" "$provider_head_sha" "$provider_check_drift_fixture"

provider_route_drift_fixture="$fixture_tmpdir/contract.provider-route-drift.json"
cp "$provider_update_fixture" "$provider_route_drift_fixture"
python3 - "$provider_route_drift_fixture" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["routes"]["submit"]["path"] = "/1/migrations/algolia-drifted"
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required \
    run_checker "$engine" "$provider_head_sha" "$provider_route_drift_fixture"

git -C "$engine" reset --quiet --hard "$head_sha"

assert_fails_action_required env -u FLAPJACK_DEV_DIR "$CHECKER" --check
assert_fails_action_required run_checker "$tmpdir/missing" "$head_sha" "$test_fixture"
mkdir "$tmpdir/not-a-repo"
assert_fails_action_required run_checker "$tmpdir/not-a-repo" "$head_sha" "$test_fixture"

git -C "$engine" commit --allow-empty -q -m "different head"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"

# The receipt's cited validation commit must be both present and reachable from
# the pinned checkout. Matching copied receipt/fixture fields are not provenance.
cp "$test_fixture" "$tmpdir/contract.before-missing-receipt-commit.json"
python3 - "$engine/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json" \
    "$test_fixture" "ffffffffffffffffffffffffffffffffffffffff" <<'PY'
import json
import pathlib
import sys

receipt_path = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
validated_head_sha = sys.argv[3]
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
receipt["validated_head_sha"] = validated_head_sha
fixture["privacy_scrub_contract"]["receipt"]["validated_head_sha"] = validated_head_sha
receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
git -C "$engine" add engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json
git -C "$engine" commit -q -m "copied receipt with missing validation commit"
missing_receipt_head="$(git -C "$engine" rev-parse HEAD)"
python3 - "$test_fixture" "$missing_receipt_head" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["pinned_engine_sha"] = sys.argv[2]
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 \
    run_checker "$engine" "$missing_receipt_head" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"
mv "$tmpdir/contract.before-missing-receipt-commit.json" "$test_fixture"

unreachable_receipt_sha="$(
    printf '%s\n' "unreachable receipt validation" |
        git -C "$engine" commit-tree "$(git -C "$engine" rev-parse HEAD^{tree})"
)"
cp "$test_fixture" "$tmpdir/contract.before-unreachable-receipt-commit.json"
python3 - "$engine/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json" \
    "$test_fixture" "$unreachable_receipt_sha" <<'PY'
import json
import pathlib
import sys

receipt_path = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
validated_head_sha = sys.argv[3]
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
receipt["validated_head_sha"] = validated_head_sha
fixture["privacy_scrub_contract"]["receipt"]["validated_head_sha"] = validated_head_sha
receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
git -C "$engine" add engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json
git -C "$engine" commit -q -m "copied receipt with unreachable validation commit"
unreachable_receipt_head="$(git -C "$engine" rev-parse HEAD)"
python3 - "$test_fixture" "$unreachable_receipt_head" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["pinned_engine_sha"] = sys.argv[2]
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 \
    run_checker "$engine" "$unreachable_receipt_head" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"
mv "$tmpdir/contract.before-unreachable-receipt-commit.json" "$test_fixture"

# Even if a copied fixture and a clean pinned script agree on an aggregate
# summary, that summary is not a privacy-scrub-specific known answer.
cp "$test_fixture" "$tmpdir/contract.before-generic-suite-marker.json"
cat >"$engine/scripts/update_algolia_migration_engine_contract.sh" <<'EOF_GENERIC_MARKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'Results: 999/999 passed (0 skipped)'
EOF_GENERIC_MARKER
chmod +x "$engine/scripts/update_algolia_migration_engine_contract.sh"
git -C "$engine" add scripts/update_algolia_migration_engine_contract.sh
git -C "$engine" commit -q -m "generic suite marker"
generic_marker_head="$(git -C "$engine" rev-parse HEAD)"
python3 - "$test_fixture" "$generic_marker_head" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["pinned_engine_sha"] = sys.argv[2]
payload["privacy_scrub_known_answer"]["success_marker"] = (
    "Results: 999/999 passed (0 skipped)"
)
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required \
    run_checker "$engine" "$generic_marker_head" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"
mv "$tmpdir/contract.before-generic-suite-marker.json" "$test_fixture"

printf '\n' >>"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/docs2/openapi.json

printf '\n' >>"$engine/engine/demo-dualclient/public/openapi.json"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/demo-dualclient/public/openapi.json

printf '{invalid json\n' >"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/docs2/openapi.json

cp "$test_fixture" "$tmpdir/contract.before-missing-ack.json"
python3 - "$engine" "$test_fixture" <<'PY'
import hashlib
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
for artifact in fixture["openapi_artifacts"]:
    path = engine / artifact["path"]
    payload = json.loads(path.read_text(encoding="utf-8"))
    del payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-missing-ack.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-ack-auth-drift.json"
python3 - "$engine" "$test_fixture" <<'PY'
import hashlib
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
for artifact in fixture["openapi_artifacts"]:
    path = engine / artifact["path"]
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"]["security"] = []
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-ack-auth-drift.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-missing-scrub.json"
python3 - "$engine" "$test_fixture" <<'PY'
import hashlib
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
for artifact in fixture["openapi_artifacts"]:
    path = engine / artifact["path"]
    payload = json.loads(path.read_text(encoding="utf-8"))
    del payload["paths"]["/1/migrations/privacy-scrub"]
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-missing-scrub.json" "$test_fixture"

# The pinned contract must reject wire-type drift, not only field-name drift. Each
# mutation rewrites a privacy-scrub property type in the engine OpenAPI (both artifacts)
# while leaving field names intact, and the checker must fail closed with exit 3.
scrub_type_mutation() {
    local label="$1"
    local schema_name="$2"
    local field="$3"
    local new_type="$4"
    local mode="$5"
    cp "$test_fixture" "$tmpdir/contract.before-$label.json"
    python3 - "$engine" "$test_fixture" "$schema_name" "$field" "$new_type" "$mode" <<'PY'
import hashlib
import json
import pathlib
import sys

engine = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
schema_name, field, new_type, mode = sys.argv[3:7]
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
for artifact in fixture["openapi_artifacts"]:
    path = engine / artifact["path"]
    payload = json.loads(path.read_text(encoding="utf-8"))
    prop = payload["components"]["schemas"][schema_name]["properties"][field]
    if mode == "scalar":
        prop["type"] = new_type
    elif mode == "array_item":
        prop["items"]["type"] = new_type
    else:
        raise SystemExit(f"unknown mutation mode {mode}")
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
    assert_fails_with_status 3 run_checker "$engine" "$head_sha" "$test_fixture"
    git -C "$engine" checkout --quiet -- \
        engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
    mv "$tmpdir/contract.before-$label.json" "$test_fixture"
}

scrub_type_mutation scrub-request-scalar-type PrivacyScrubRequest scrubId integer scalar
scrub_type_mutation scrub-ack-scalar-type PrivacyScrubAck disposition integer scalar
scrub_type_mutation scrub-request-array-item-type PrivacyScrubRequest objectIDs integer array_item

cp "$engine/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json" \
    "$tmpdir/privacy-scrub-receipt.before"
python3 - "$engine/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["denominators"]["boundary_variants"]["variants"].remove("AckReplay")
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$head_sha" "$test_fixture"
mv "$tmpdir/privacy-scrub-receipt.before" \
    "$engine/engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json"

cp "$engine/scripts/update_algolia_migration_engine_contract.sh" \
    "$tmpdir/ack-known-answer.before"
cat >"$engine/scripts/update_algolia_migration_engine_contract.sh" <<'EOF_ACK_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'PASS route_exists_only'
EOF_ACK_STUB
chmod +x "$engine/scripts/update_algolia_migration_engine_contract.sh"
assert_fails_with_status 3 run_checker "$engine" "$head_sha" "$test_fixture"
mv "$tmpdir/ack-known-answer.before" \
    "$engine/scripts/update_algolia_migration_engine_contract.sh"

cp "$test_fixture" "$tmpdir/contract.before-drift.json"
python3 - "$test_fixture" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.loads(open(path, encoding="utf-8").read())
payload["routes"]["submit"]["path"] = "/1/migrations/algolia-drifted"
open(path, "w", encoding="utf-8").write(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
mv "$tmpdir/contract.before-drift.json" "$test_fixture"

printf 'PASS update_algolia_migration_engine_contract_test\n'
