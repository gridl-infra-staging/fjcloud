#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/flapjack_binary.sh
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"

PINNED_ENGINE_SHA="${FJCLOUD_ALGOLIA_MIGRATION_ENGINE_PINNED_SHA_FOR_TEST:-a025a5eb43025b0680cfc78e5e07ec6c052695a4}"
DEFAULT_FIXTURE="$REPO_ROOT/infra/api/tests/fixtures/algolia_migration_engine_contract.json"

usage() {
    cat >&2 <<'EOF'
usage: scripts/update_algolia_migration_engine_contract.sh --check [--fixture PATH]
EOF
}

action_required() {
    printf 'ACTION_REQUIRED: %s\n' "$*" >&2
    exit 1
}

mode=""
fixture="$DEFAULT_FIXTURE"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            mode="check"
            shift
            ;;
        --fixture)
            [ "$#" -ge 2 ] || action_required "--fixture requires a path"
            fixture="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            action_required "unknown argument: $1"
            ;;
    esac
done

[ "$mode" = "check" ] || {
    usage
    action_required "only explicit --check mode is supported"
}

[ -n "${FLAPJACK_DEV_DIR:-}" ] || action_required "FLAPJACK_DEV_DIR must point at the pinned flapjack checkout"
[ -d "$FLAPJACK_DEV_DIR" ] || action_required "FLAPJACK_DEV_DIR does not exist: $FLAPJACK_DEV_DIR"
[ -f "$fixture" ] || action_required "contract fixture is missing: $fixture"

source_root="$(flapjack_source_root "$FLAPJACK_DEV_DIR" || true)"
[ -n "$source_root" ] || action_required "FLAPJACK_DEV_DIR is not a flapjack source checkout: $FLAPJACK_DEV_DIR"

git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$git_root" ] || action_required "flapjack source checkout is not a git repository: $source_root"

actual_head="$(git -C "$git_root" rev-parse HEAD 2>/dev/null || true)"
[ -n "$actual_head" ] || action_required "could not determine flapjack checkout HEAD"
[ "$actual_head" = "$PINNED_ENGINE_SHA" ] || action_required "flapjack checkout HEAD $actual_head does not match pinned $PINNED_ENGINE_SHA"

python3 - "$git_root" "$fixture" "$PINNED_ENGINE_SHA" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

git_root = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
pinned_sha = sys.argv[3]

def action_required(message: str) -> None:
    print(f"ACTION_REQUIRED: {message}", file=sys.stderr)
    raise SystemExit(1)

def load_json(path: pathlib.Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except FileNotFoundError:
        action_required(f"missing JSON artifact: {path}")
    except OSError as exc:
        action_required(f"could not read JSON artifact {path}: {exc}")
    except json.JSONDecodeError as exc:
        action_required(f"invalid JSON artifact {path}: {exc}")
    if not isinstance(payload, dict):
        action_required(f"JSON artifact is not an object: {path}")
    return payload

fixture = load_json(fixture_path)
if fixture.get("pinned_engine_sha") != pinned_sha:
    action_required(
        f"fixture pinned_engine_sha {fixture.get('pinned_engine_sha')!r} does not match {pinned_sha}"
    )

def schema(payload: dict, name: str) -> dict:
    schemas = payload.get("components", {}).get("schemas", {})
    value = schemas.get(name)
    if not isinstance(value, dict):
        action_required(f"OpenAPI artifact is missing schema {name}")
    return value

def path_method(payload: dict, path: str, method: str) -> None:
    paths = payload.get("paths", {})
    path_value = paths.get(path)
    if not isinstance(path_value, dict):
        action_required(f"OpenAPI artifact is missing path {path}")
    if method.lower() not in path_value:
        action_required(f"OpenAPI artifact is missing {method} {path}")

def sorted_required(payload: dict, name: str) -> list[str]:
    value = schema(payload, name).get("required", [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        action_required(f"schema {name} required field list is invalid")
    return sorted(value)

def sorted_optional(payload: dict, name: str) -> list[str]:
    body = schema(payload, name)
    properties = body.get("properties", {})
    if not isinstance(properties, dict):
        action_required(f"schema {name} properties are invalid")
    return sorted(set(properties) - set(sorted_required(payload, name)))

def enum_values(payload: dict, name: str) -> list[str]:
    value = schema(payload, name).get("enum")
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        action_required(f"schema {name} enum is invalid")
    return value

def response_codes(payload: dict) -> dict:
    # The pinned handler owns these stable typed failure codes. OpenAPI owns the
    # route/status presence, while the committed fixture keeps the exact code
    # names from Stage 1 handler evidence.
    discovered: dict[str, dict[str, int]] = {}
    checks = {
        "migration_ha_unsupported": ("/1/migrations/algolia", "post", "503"),
        "migration_capacity_exhausted": ("/1/migrations/algolia", "post", "503"),
        "migration_job_not_found": ("/1/migrations/algolia/{job_id}", "get", "404"),
        "cancel_too_late": ("/1/migrations/algolia/{job_id}/cancel", "post", "409"),
    }
    paths = payload.get("paths", {})
    for code, (path, method, status) in checks.items():
        operation = paths.get(path, {}).get(method, {})
        responses = operation.get("responses", {})
        if status not in responses:
            action_required(f"OpenAPI artifact is missing HTTP {status} for {method.upper()} {path}")
        discovered[code] = {"http_status": int(status)}
    return discovered

def extract_contract(payload: dict) -> dict:
    path_method(payload, "/1/migrations/algolia", "POST")
    path_method(payload, "/1/migrations/algolia/{job_id}", "GET")
    path_method(payload, "/1/migrations/algolia/{job_id}/cancel", "POST")
    return {
        "routes": {
            "submit": {"method": "POST", "path": "/1/migrations/algolia"},
            "status": {"method": "GET", "path": "/1/migrations/algolia/{job_id}"},
            "cancel": {"method": "POST", "path": "/1/migrations/algolia/{job_id}/cancel"},
        },
        "request": {
            "required_fields": sorted_required(payload, "MigrateFromAlgoliaRequest"),
            "optional_fields": sorted_optional(payload, "MigrateFromAlgoliaRequest"),
        },
        "status": {
            "required_fields": sorted_required(payload, "AsyncMigrationStatusResponse"),
            "optional_fields": sorted_optional(payload, "AsyncMigrationStatusResponse"),
        },
        "progress": {
            "required_fields": sorted_required(payload, "AsyncMigrationExportProgress"),
            "optional_fields": sorted_optional(payload, "AsyncMigrationExportProgress"),
        },
        "enums": {
            "phase": enum_values(payload, "AsyncMigrationPhase"),
            "disposition": enum_values(payload, "AsyncMigrationDisposition"),
        },
        "errors": response_codes(payload),
    }

fixture_artifacts = fixture.get("openapi_artifacts")
if not isinstance(fixture_artifacts, list) or not fixture_artifacts:
    action_required("fixture openapi_artifacts must be a nonempty list")

expected_without_meta = {
    key: copy.deepcopy(fixture[key])
    for key in ["routes", "request", "status", "progress", "enums", "errors"]
}

baseline_contract = None
for artifact in fixture_artifacts:
    if not isinstance(artifact, dict):
        action_required("fixture openapi_artifacts entries must be objects")
    rel_path = artifact.get("path")
    expected_sha = artifact.get("sha256")
    if not isinstance(rel_path, str) or not isinstance(expected_sha, str):
        action_required("fixture artifact path and sha256 must be strings")
    artifact_path = git_root / rel_path
    if not artifact_path.exists():
        action_required(f"missing OpenAPI artifact: {rel_path}")
    try:
        raw = artifact_path.read_bytes()
    except OSError as exc:
        action_required(f"could not read OpenAPI artifact {rel_path}: {exc}")
    actual_sha = hashlib.sha256(raw).hexdigest()
    if actual_sha != expected_sha:
        action_required(f"OpenAPI artifact {rel_path} sha256 {actual_sha} does not match fixture {expected_sha}")
    try:
        artifact_payload = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as exc:
        action_required(f"invalid UTF-8 in OpenAPI artifact {rel_path}: {exc}")
    except json.JSONDecodeError as exc:
        action_required(f"invalid JSON in OpenAPI artifact {rel_path}: {exc}")
    extracted = extract_contract(artifact_payload)
    if extracted != expected_without_meta:
        action_required(f"OpenAPI artifact {rel_path} normalized contract differs from fixture")
    if baseline_contract is None:
        baseline_contract = extracted
    elif extracted != baseline_contract:
        action_required(f"OpenAPI artifact {rel_path} normalized contract differs from first artifact")

print("Algolia migration engine contract is current")
PY
