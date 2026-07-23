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
    local expected_sha="$2"
    local fixture_path="$3"
    shift 3
    FLAPJACK_DEV_DIR="$engine_dir" \
        FJCLOUD_ALGOLIA_MIGRATION_ENGINE_PINNED_SHA_FOR_TEST="$expected_sha" \
        "$CHECKER" --check --fixture "$fixture_path" "$@"
}

assert_action_required() {
    local output="$1"
    grep -q 'ACTION_REQUIRED' "$output" || {
        cat "$output" >&2
        fail "expected ACTION_REQUIRED diagnostic"
    }
}

assert_fails_action_required() {
    local output="$tmpdir/output.$RANDOM"
    if "$@" >"$output" 2>&1; then
        cat "$output" >&2
        fail "expected command to fail"
    fi
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
for artifact in payload["openapi_artifacts"]:
    artifact["sha256"] = artifact_sha
open(path, "w", encoding="utf-8").write(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY

snapshot_paths "$engine" "$CHECKER" "$test_fixture" "$FIXTURE" >"$tmpdir/read_only.before"

run_checker "$engine" "$head_sha" "$test_fixture"

snapshot_paths "$engine" "$CHECKER" "$test_fixture" "$FIXTURE" >"$tmpdir/read_only.after"
cmp -s "$tmpdir/read_only.before" "$tmpdir/read_only.after" || {
    diff -u "$tmpdir/read_only.before" "$tmpdir/read_only.after" >&2 || true
    fail "--check modified an engine or contract input"
}

assert_fails_action_required env -u FLAPJACK_DEV_DIR "$CHECKER" --check
assert_fails_action_required run_checker "$tmpdir/missing" "$head_sha" "$test_fixture"
mkdir "$tmpdir/not-a-repo"
assert_fails_action_required run_checker "$tmpdir/not-a-repo" "$head_sha" "$test_fixture"

git -C "$engine" commit --allow-empty -q -m "different head"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" reset --quiet --hard "$head_sha"

printf '\n' >>"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/docs2/openapi.json

printf '\n' >>"$engine/engine/demo-dualclient/public/openapi.json"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/demo-dualclient/public/openapi.json

printf '{invalid json\n' >"$engine/engine/docs2/openapi.json"
assert_fails_action_required run_checker "$engine" "$head_sha" "$test_fixture"
git -C "$engine" checkout --quiet -- engine/docs2/openapi.json

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
