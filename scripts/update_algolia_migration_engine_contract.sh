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
import subprocess
import sys

git_root = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
pinned_sha = sys.argv[3]

def action_required(message: str, exit_code: int = 1) -> None:
    print(f"ACTION_REQUIRED: {message}", file=sys.stderr)
    raise SystemExit(exit_code)

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

def validate_required_runtime_routes(fixture: dict, payload: dict) -> None:
    routes = fixture.get("required_runtime_routes")
    if not isinstance(routes, dict) or not routes:
        action_required("fixture required_runtime_routes must be a nonempty object")
    for name, route in routes.items():
        if not isinstance(name, str) or not isinstance(route, dict):
            action_required("fixture required_runtime_routes entries must be named objects")
        method = route.get("method")
        path = route.get("path")
        if not isinstance(method, str) or not isinstance(path, str):
            action_required(f"fixture required runtime route {name} must define method and path")
        paths = payload.get("paths", {})
        path_value = paths.get(path)
        if not isinstance(path_value, dict) or method.lower() not in path_value:
            action_required(
                f"OpenAPI artifact is missing required runtime route {method} {path}",
                exit_code=3,
            )
        if name == "acknowledge":
            validate_acknowledgement_contract(fixture, path_value[method.lower()])

def validate_acknowledgement_contract(fixture: dict, operation: dict) -> None:
    expected = fixture.get("acknowledgement_contract")
    if not isinstance(expected, dict) or not expected:
        action_required("fixture acknowledgement_contract must be a nonempty object")
    if not isinstance(operation, dict):
        action_required("OpenAPI artifact ACK operation must be an object", exit_code=3)
    observed = operation.get("x-fjcloud-terminal-ack-contract")
    if observed != expected:
        action_required(
            "OpenAPI artifact ACK route is missing required authentication/durability/idempotency/absence contract",
            exit_code=3,
        )

def acknowledgement_known_answer_config(fixture: dict) -> tuple[list[str], str]:
    known_answer = fixture.get("acknowledgement_known_answer")
    if not isinstance(known_answer, dict):
        action_required("fixture acknowledgement_known_answer must be an object")
    command = known_answer.get("command")
    success_marker = known_answer.get("success_marker")
    if (
        not isinstance(command, list)
        or not command
        or any(not isinstance(argument, str) or not argument for argument in command)
        or not isinstance(success_marker, str)
        or not success_marker
    ):
        action_required(
            "fixture acknowledgement_known_answer must define command and success_marker"
        )
    if command[0] != "bash" or len(command) != 2:
        action_required("engine ACK known-answer command must be one pinned bash script")
    return command, success_marker

def require_pinned_known_answer_script(command: list[str]) -> None:
    script_path = pathlib.PurePosixPath(command[1])
    if script_path.is_absolute() or ".." in script_path.parts:
        action_required("engine ACK known-answer script path must stay inside the engine checkout")
    script_file = git_root / script_path
    if not script_file.is_file() or script_file.is_symlink():
        action_required("engine ACK known-answer script is missing", exit_code=3)
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", command[1]],
        cwd=git_root,
        check=False,
        capture_output=True,
        text=True,
    )
    clean = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--", command[1]],
        cwd=git_root,
        check=False,
    )
    if tracked.returncode != 0 or clean.returncode != 0:
        action_required(
            "engine ACK known-answer script must be the pinned tracked source",
            exit_code=3,
        )

def run_acknowledgement_known_answer(fixture: dict) -> None:
    command, success_marker = acknowledgement_known_answer_config(fixture)
    require_pinned_known_answer_script(command)
    try:
        completed = subprocess.run(
            command,
            cwd=git_root,
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        action_required("engine ACK known-answer test could not run", exit_code=3)
    output_lines = completed.stdout.splitlines()
    if completed.returncode != 0 or output_lines.count(success_marker) != 1:
        action_required(
            "engine ACK known-answer test did not prove authentication/durability/idempotency/absence semantics",
            exit_code=3,
        )

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
    validate_required_runtime_routes(fixture, artifact_payload)
    extracted = extract_contract(artifact_payload)
    if extracted != expected_without_meta:
        action_required(f"OpenAPI artifact {rel_path} normalized contract differs from fixture")
    if baseline_contract is None:
        baseline_contract = extracted
    elif extracted != baseline_contract:
        action_required(f"OpenAPI artifact {rel_path} normalized contract differs from first artifact")

run_acknowledgement_known_answer(fixture)
print("Algolia migration engine contract is current")
PY
