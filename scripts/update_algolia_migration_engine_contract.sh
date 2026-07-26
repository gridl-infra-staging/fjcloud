#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/flapjack_binary.sh
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"

DEFAULT_FIXTURE="$REPO_ROOT/infra/api/tests/fixtures/algolia_migration_engine_contract.json"
ACK_SEMANTIC_CHECK="${FJCLOUD_ALGOLIA_MIGRATION_ENGINE_ACK_SEMANTIC_CHECK:-}"

usage() {
    cat >&2 <<'EOF'
usage: scripts/update_algolia_migration_engine_contract.sh (--check|--update) [--fixture PATH]
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
        --update)
            mode="update"
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

[ "$mode" = "check" ] || [ "$mode" = "update" ] || {
    usage
    action_required "explicit --check or --update mode is required"
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
if ! checkout_status="$(git -C "$git_root" status --porcelain 2>/dev/null)"; then
    action_required "could not determine whether flapjack checkout is clean"
fi
checkout_clean="false"
[ -n "$checkout_status" ] || checkout_clean="true"

run_ack_semantic_check() {
    if [ -n "$ACK_SEMANTIC_CHECK" ]; then
        [ -x "$ACK_SEMANTIC_CHECK" ] || action_required "ACK semantic check override is not executable: $ACK_SEMANTIC_CHECK"
        "$ACK_SEMANTIC_CHECK" "$git_root/engine" \
            || action_required "engine ACK semantic check override failed"
        return 0
    fi
    cargo test --quiet -p flapjack-http x_algolia_application_id_required \
        --manifest-path "$git_root/engine/Cargo.toml" \
        || action_required "engine ACK semantic proof missing required x-algolia-application-id guard"
    cargo test --quiet -p flapjack-http \
        async_acknowledge_running_job_fails_closed_without_mutating_phase \
        --manifest-path "$git_root/engine/Cargo.toml" \
        || action_required "engine ACK semantic proof missing migration_ack_too_early fail-closed behavior"
}

run_ack_semantic_check

python3 - "$git_root" "$fixture" "$actual_head" "$mode" "$checkout_clean" <<'PY'
import copy
import hashlib
import json
import os
import pathlib
import sys
import tempfile

git_root = pathlib.Path(sys.argv[1])
fixture_path = pathlib.Path(sys.argv[2])
actual_head = sys.argv[3]
mode = sys.argv[4]
checkout_clean = sys.argv[5] == "true"
resolved_git_root = git_root.resolve()

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

def resolve_checkout_artifact(rel_path: str) -> pathlib.Path:
    candidate = resolved_git_root / rel_path
    resolved = candidate.resolve()
    try:
        resolved.relative_to(resolved_git_root)
    except ValueError:
        action_required(f"fixture artifact path escapes flapjack checkout: {rel_path}")
    return resolved

def required_object_field(payload: object, field: str, owner: str) -> dict:
    if not isinstance(payload, dict):
        action_required(f"{owner} must be an object")
    value = payload.get(field)
    if not isinstance(value, dict):
        action_required(f"{owner} {field} must be an object")
    return value

fixture = load_json(fixture_path)
pinned_engine_sha = fixture.get("pinned_engine_sha")
if not isinstance(pinned_engine_sha, str):
    action_required("fixture pinned_engine_sha must be a string")
if mode == "check" and pinned_engine_sha != actual_head:
    action_required(
        f"flapjack checkout HEAD {actual_head} does not match fixture pinned_engine_sha {pinned_engine_sha}"
    )

def schema(payload: dict, name: str) -> dict:
    components = required_object_field(payload, "components", "OpenAPI artifact")
    schemas = required_object_field(components, "schemas", "OpenAPI artifact components")
    value = schemas.get(name)
    if not isinstance(value, dict):
        action_required(f"OpenAPI artifact is missing schema {name}")
    return value

def path_method(payload: dict, path: str, method: str) -> None:
    paths = required_object_field(payload, "paths", "OpenAPI artifact")
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
        paths = required_object_field(payload, "paths", "OpenAPI artifact")
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
    security = operation.get("security")
    if not isinstance(security, list) or {"api_key": []} not in security:
        action_required("OpenAPI artifact ACK route must require api_key security", exit_code=3)
    responses = operation.get("responses", {})
    if not isinstance(responses, dict):
        action_required("OpenAPI artifact ACK operation responses must be an object", exit_code=3)
    for name, status in {
        "already_acknowledged": "204",
        "absence/missing_job": "404",
        "too_early": "409",
    }.items():
        if status not in responses:
            action_required(
                f"OpenAPI artifact ACK route is missing {name} HTTP {status}",
                exit_code=3,
            )
    absence = required_object_field(
        expected,
        "absence",
        "fixture acknowledgement_contract",
    )
    missing_job = required_object_field(
        absence,
        "missing_job",
        "fixture acknowledgement_contract absence",
    )
    too_early = required_object_field(
        expected,
        "too_early",
        "fixture acknowledgement_contract",
    )
    validate_response_allows_status_only(
        responses["404"],
        missing_job.get("code"),
        "OpenAPI artifact ACK route documents a conflicting missing_job code",
    )
    validate_response_contains_code(
        responses["409"],
        too_early.get("code"),
        "OpenAPI artifact ACK route is missing pinned too_early code",
    )

def response_contains_string(node: object, expected: str) -> bool:
    if isinstance(node, str):
        return expected in node
    if isinstance(node, dict):
        return any(response_contains_string(value, expected) for value in node.values())
    if isinstance(node, list):
        return any(response_contains_string(value, expected) for value in node)
    return False

def response_code_values(node: object) -> list[str]:
    if isinstance(node, dict):
        values: list[str] = []
        for key, value in node.items():
            if key == "code" and isinstance(value, str):
                values.append(value)
            values.extend(response_code_values(value))
        return values
    if isinstance(node, list):
        values: list[str] = []
        for value in node:
            values.extend(response_code_values(value))
        return values
    return []

def validate_response_contains_code(response: object, expected_code: object, message: str) -> None:
    if not isinstance(expected_code, str) or not expected_code:
        action_required("fixture-pinned response code must be a nonempty string")
    observed_codes = response_code_values(response)
    if observed_codes:
        if expected_code in observed_codes:
            return
        action_required(message, exit_code=3)
    if response_contains_string(response, expected_code):
        return
    action_required(message, exit_code=3)

def validate_response_allows_status_only(response: object, expected_code: object, message: str) -> None:
    if not isinstance(expected_code, str) or not expected_code:
        action_required("fixture-pinned response code must be a nonempty string")
    observed_codes = response_code_values(response)
    if observed_codes and expected_code not in observed_codes:
        action_required(message, exit_code=3)

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
        "migration_ha_unsupported": ("/1/migrations/algolia", "post", "503", True),
        "migration_capacity_exhausted": ("/1/migrations/algolia", "post", "503", True),
        "migration_job_not_found": ("/1/migrations/algolia/{job_id}", "get", "404", False),
        "cancel_too_late": ("/1/migrations/algolia/{job_id}/cancel", "post", "409", True),
    }
    paths = required_object_field(payload, "paths", "OpenAPI artifact")
    for code, (path, method, status, require_code_documentation) in checks.items():
        path_value = required_object_field(paths, path, "OpenAPI artifact paths")
        operation = required_object_field(
            path_value,
            method,
            f"OpenAPI artifact path {path}",
        )
        responses = required_object_field(
            operation,
            "responses",
            f"OpenAPI artifact {method.upper()} {path}",
        )
        if status not in responses:
            action_required(f"OpenAPI artifact is missing HTTP {status} for {method.upper()} {path}")
        message = f"OpenAPI artifact HTTP {status} for {method.upper()} {path} is missing pinned code {code}"
        if require_code_documentation:
            validate_response_contains_code(responses[status], code, message)
        else:
            validate_response_allows_status_only(responses[status], code, message)
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
    key: copy.deepcopy(required_object_field(fixture, key, "fixture"))
    for key in ["routes", "request", "status", "progress", "enums", "errors"]
}

baseline_contract = None
actual_artifact_shas: dict[str, str] = {}
for artifact in fixture_artifacts:
    if not isinstance(artifact, dict):
        action_required("fixture openapi_artifacts entries must be objects")
    rel_path = artifact.get("path")
    expected_sha = artifact.get("sha256")
    if not isinstance(rel_path, str) or not isinstance(expected_sha, str):
        action_required("fixture artifact path and sha256 must be strings")
    artifact_path = resolve_checkout_artifact(rel_path)
    if not artifact_path.exists():
        action_required(f"missing OpenAPI artifact: {rel_path}")
    try:
        raw = artifact_path.read_bytes()
    except OSError as exc:
        action_required(f"could not read OpenAPI artifact {rel_path}: {exc}")
    actual_sha = hashlib.sha256(raw).hexdigest()
    actual_artifact_shas[rel_path] = actual_sha
    if mode == "check" and actual_sha != expected_sha:
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

if not checkout_clean:
    action_required("flapjack checkout must be clean before contract validation")

if mode == "update":
    updated = copy.deepcopy(fixture)
    updated["pinned_engine_sha"] = actual_head
    for artifact in updated["openapi_artifacts"]:
        artifact["sha256"] = actual_artifact_shas[artifact["path"]]
    if updated != fixture:
        encoded = json.dumps(updated, indent=2).encode("utf-8") + b"\n"
        fixture_path.parent.mkdir(parents=True, exist_ok=True)
        temp_name = None
        try:
            with tempfile.NamedTemporaryFile(
                "wb",
                dir=fixture_path.parent,
                prefix=f".{fixture_path.name}.",
                delete=False,
            ) as temp:
                temp.write(encoded)
                temp.flush()
                os.fsync(temp.fileno())
                temp_name = pathlib.Path(temp.name)
            os.replace(temp_name, fixture_path)
        finally:
            if temp_name is not None and temp_name.exists():
                temp_name.unlink()
    print("Algolia migration engine contract updated")
else:
    print("Algolia migration engine contract is current")
PY
