#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/update_algolia_migration_engine_contract.sh"
FIXTURE="$REPO_ROOT/infra/api/tests/fixtures/algolia_migration_engine_contract.json"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

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
        "security": [{"api_key": []}],
        "responses": {
          "204": {"description": "Acknowledged"},
          "404": {
            "description": "Not found",
            "content": {"application/json": {"examples": {
              "migration_job_not_found": {"value": {"code": "migration_job_not_found"}}
            }}}
          },
          "409": {
            "description": "migration_ack_too_early",
            "content": {"application/json": {"examples": {
              "migration_ack_too_early": {"value": {"code": "migration_ack_too_early"}}
            }}}
          }
        }
      }
    }
  },
  "components": {
    "securitySchemes": {
      "api_key": {
        "type": "apiKey",
        "in": "header",
        "name": "x-algolia-api-key"
      }
    },
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
          "terminalAt": {"type": "string"}
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
      }
    }
  }
}
JSON
}

init_engine_repo() {
    local dir="$1"
    mkdir -p "$dir/engine"
    cat >"$dir/engine/Cargo.toml" <<'EOF_CARGO'
[package]
name = "flapjack-server"
version = "0.0.0"
EOF_CARGO
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
    local fixture_path="$2"
    shift 2
    local ack_check="$tmpdir/ack-semantic-check"
    FLAPJACK_DEV_DIR="$engine_dir" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_ACK_SEMANTIC_CHECK="$ack_check" \
        "$CHECKER" --check --fixture "$fixture_path" "$@"
}

run_updater() {
    local engine_dir="$1"
    local fixture_path="$2"
    shift 2
    local ack_check="$tmpdir/ack-semantic-check"
    FLAPJACK_DEV_DIR="$engine_dir" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_ACK_SEMANTIC_CHECK="$ack_check" \
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
head_sha="$(git -C "$engine" rev-parse HEAD)"
artifact_sha="$(shasum -a 256 "$engine/engine/docs2/openapi.json" | awk '{print $1}')"
test_fixture="$tmpdir/contract.json"
cp "$FIXTURE" "$test_fixture"
python3 - "$test_fixture" "$head_sha" "$artifact_sha" <<'PY'
import json
import sys

path, head_sha, artifact_sha = sys.argv[1:4]
payload = json.loads(open(path, encoding="utf-8").read())
payload["pinned_engine_sha"] = head_sha
payload["required_runtime_routes"] = {
    "acknowledge": {
        "method": "POST",
        "path": "/1/migrations/algolia/{job_id}/acknowledge",
    }
}
payload["acknowledgement_contract"] = {
    "authentication": {
        "required": True,
        "headers": ["x-algolia-api-key", "x-algolia-application-id"],
    },
    "durability": {
        "terminal_phase_required_before_success": True,
    },
    "idempotency": {
        "duplicate_terminal_acknowledgement": "success_no_mutation",
    },
    "absence": {
        "missing_job": {
            "http_status": 404,
            "code": "migration_job_not_found",
        },
    },
    "already_acknowledged": {
        "http_status": 204,
    },
    "too_early": {
        "http_status": 409,
        "code": "migration_ack_too_early",
    },
}
for artifact in payload["openapi_artifacts"]:
    artifact["sha256"] = artifact_sha
open(path, "w", encoding="utf-8").write(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY

snapshot_paths "$engine" "$CHECKER" "$test_fixture" "$FIXTURE" >"$tmpdir/read_only.before"

run_checker "$engine" "$test_fixture"
grep -q '/engine$' "$ACK_CHECK_LOG" || fail "ACK semantic check should receive an engine path"

snapshot_paths "$engine" "$CHECKER" "$test_fixture" "$FIXTURE" >"$tmpdir/read_only.after"
cmp -s "$tmpdir/read_only.before" "$tmpdir/read_only.after" || {
    diff -u "$tmpdir/read_only.before" "$tmpdir/read_only.after" >&2 || true
    fail "--check modified an engine or contract input"
}

missing_contract_section_fixture="$tmpdir/contract.missing-routes.json"
cp "$test_fixture" "$missing_contract_section_fixture"
python3 - "$missing_contract_section_fixture" <<'PY'
import json
import pathlib
import sys

fixture_path = pathlib.Path(sys.argv[1])
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
del fixture["routes"]
fixture_path.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required run_checker "$engine" "$missing_contract_section_fixture"

malformed_ack_contract_fixture="$tmpdir/contract.malformed-ack-absence.json"
cp "$test_fixture" "$malformed_ack_contract_fixture"
python3 - "$malformed_ack_contract_fixture" <<'PY'
import json
import pathlib
import sys

fixture_path = pathlib.Path(sys.argv[1])
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
fixture["acknowledgement_contract"]["absence"] = []
fixture_path.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required run_checker "$engine" "$malformed_ack_contract_fixture"

cp "$test_fixture" "$tmpdir/contract.before-description-only-errors.json"
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
    payload["paths"]["/1/migrations/algolia"]["post"]["responses"]["503"] = {
        "description": "migration_ha_unsupported or migration_capacity_exhausted"
    }
    payload["paths"]["/1/migrations/algolia/{job_id}"]["get"]["responses"]["404"] = {
        "description": "No durable migration phase record is currently retained for the UUID"
    }
    payload["paths"]["/1/migrations/algolia/{job_id}/cancel"]["post"]["responses"]["409"] = {
        "description": "cancel_too_late"
    }
    payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"]["responses"]["404"] = {
        "description": "No durable migration phase record is currently retained for the UUID"
    }
    payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"]["responses"]["409"] = {
        "description": "migration_ack_too_early"
    }
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
git -C "$engine" add engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
git -C "$engine" commit -q -m "description only error responses"
description_only_head="$(git -C "$engine" rev-parse HEAD)"
python3 - "$test_fixture" "$description_only_head" <<'PY'
import json
import sys

fixture_path, head_sha = sys.argv[1:3]
fixture = json.loads(open(fixture_path, encoding="utf-8").read())
fixture["pinned_engine_sha"] = head_sha
open(fixture_path, "w", encoding="utf-8").write(json.dumps(fixture, sort_keys=True, indent=2) + "\n")
PY
run_checker "$engine" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"
mv "$tmpdir/contract.before-description-only-errors.json" "$test_fixture"

update_fixture="$tmpdir/contract.update.json"
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
run_updater "$engine" "$update_fixture"
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
cp "$update_fixture" "$tmpdir/contract.update.once.json"
run_updater "$engine" "$update_fixture"
cmp -s "$tmpdir/contract.update.once.json" "$update_fixture" \
    || fail "--update must be byte-identical on a second update"

cp "$tmpdir/contract.update.once.json" "$tmpdir/contract.update.semantic-fail.json"
ACK_CHECK_SCENARIO=fail assert_fails_action_required run_updater "$engine" "$tmpdir/contract.update.semantic-fail.json"
cmp -s "$tmpdir/contract.update.once.json" "$tmpdir/contract.update.semantic-fail.json" \
    || fail "--update changed fixture after semantic validation failed"

cp "$tmpdir/contract.update.once.json" "$tmpdir/contract.update.artifact-fail.json"
cp "$engine/engine/docs2/openapi.json" "$tmpdir/openapi.before-update-fail.json"
printf '{invalid json\n' >"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_updater "$engine" "$tmpdir/contract.update.artifact-fail.json"
cmp -s "$tmpdir/contract.update.once.json" "$tmpdir/contract.update.artifact-fail.json" \
    || fail "--update changed fixture after artifact validation failed"
printf '[]\n' >"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_updater "$engine" "$tmpdir/contract.update.artifact-fail.json"
cmp -s "$tmpdir/contract.update.once.json" "$tmpdir/contract.update.artifact-fail.json" \
    || fail "--update changed fixture after artifact shape validation failed"
mv "$tmpdir/openapi.before-update-fail.json" "$engine/engine/docs2/openapi.json"

assert_fails_action_required env -u FLAPJACK_DEV_DIR "$CHECKER" --check
assert_fails_action_required run_checker "$tmpdir/missing" "$test_fixture"
mkdir "$tmpdir/not-a-repo"
assert_fails_action_required run_checker "$tmpdir/not-a-repo" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-path-traversal.json"
cp "$engine/engine/docs2/openapi.json" "$tmpdir/escaped-openapi.json"
python3 - "$test_fixture" "$tmpdir/escaped-openapi.json" <<'PY'
import hashlib
import json
import pathlib
import sys

fixture_path = pathlib.Path(sys.argv[1])
escaped_path = pathlib.Path(sys.argv[2])
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
fixture["openapi_artifacts"][0]["path"] = "../escaped-openapi.json"
fixture["openapi_artifacts"][0]["sha256"] = hashlib.sha256(
    escaped_path.read_bytes()
).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_action_required run_checker "$engine" "$test_fixture"
mv "$tmpdir/contract.before-path-traversal.json" "$test_fixture"

real_git="$(command -v git)"
mkdir "$tmpdir/failing-git"
cat >"$tmpdir/failing-git/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    if [ "$argument" = "status" ]; then
        exit 42
    fi
done
exec "${REAL_GIT:?}" "$@"
EOF_GIT
chmod +x "$tmpdir/failing-git/git"
PATH="$tmpdir/failing-git:$PATH" REAL_GIT="$real_git" \
    assert_fails_action_required run_checker "$engine" "$test_fixture"

ACK_CHECK_SCENARIO=fail assert_fails_action_required run_checker "$engine" "$test_fixture"

git -C "$engine" commit --allow-empty -q -m "different head"
assert_fails_action_required run_checker "$engine" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"

printf '\n' >>"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/docs2/openapi.json

printf '\n' >>"$engine/engine/demo-dualclient/public/openapi.json"
assert_fails_action_required run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/demo-dualclient/public/openapi.json

printf '{invalid json\n' >"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_checker "$engine" "$test_fixture"
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
assert_fails_with_status 3 run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-missing-ack.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-ack-security.json"
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
    payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"].pop(
        "security", None
    )
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-ack-security.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-ack-too-early.json"
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
    del payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"]["responses"]["409"]
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-ack-too-early.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-ack-missing-job-code-drift.json"
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
    response = payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"]["responses"]["404"]
    response["content"] = {
        "application/json": {
            "examples": {
                "wrong_missing_job": {"value": {"code": "wrong_missing_job"}}
            }
        }
    }
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-ack-missing-job-code-drift.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-ack-code-drift.json"
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
    examples = payload["paths"]["/1/migrations/algolia/{job_id}/acknowledge"]["post"]["responses"]["409"]["content"]["application/json"]["examples"]
    examples["migration_ack_too_early"]["value"]["code"] = "wrong_ack_code"
    encoded = json.dumps(payload, indent=2).encode() + b"\n"
    path.write_bytes(encoded)
    artifact["sha256"] = hashlib.sha256(encoded).hexdigest()
fixture_path.write_text(json.dumps(fixture, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
assert_fails_with_status 3 run_checker "$engine" "$test_fixture"
git -C "$engine" checkout --quiet -- \
    engine/docs2/openapi.json engine/demo-dualclient/public/openapi.json
mv "$tmpdir/contract.before-ack-code-drift.json" "$test_fixture"

cp "$test_fixture" "$tmpdir/contract.before-drift.json"
python3 - "$test_fixture" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.loads(open(path, encoding="utf-8").read())
payload["routes"]["submit"]["path"] = "/1/migrations/algolia-drifted"
open(path, "w", encoding="utf-8").write(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY
assert_fails_action_required run_checker "$engine" "$test_fixture"
mv "$tmpdir/contract.before-drift.json" "$test_fixture"

printf 'PASS update_algolia_migration_engine_contract_test\n'
