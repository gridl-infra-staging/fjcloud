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
    # The engine checkout is shared with other workers, and its incremental
    # cache has produced `ld: symbol(s) not found` link failures that made this
    # gate report ACTION_REQUIRED for a semantic proof that actually passes.
    # A one-shot verification gate gains nothing from incremental artifacts, so
    # bypass them rather than reading a corrupt cache as a contract violation.
    CARGO_INCREMENTAL=0 cargo test --quiet -p flapjack-http x_algolia_application_id_required \
        --manifest-path "$git_root/engine/Cargo.toml" \
        || action_required "engine ACK semantic proof missing required x-algolia-application-id guard"
    CARGO_INCREMENTAL=0 cargo test --quiet -p flapjack-http \
        async_acknowledge_running_job_fails_closed_without_mutating_phase \
        --manifest-path "$git_root/engine/Cargo.toml" \
        || action_required "engine ACK semantic proof missing migration_ack_too_early fail-closed behavior"
}

run_ack_semantic_check

python3 - "$REPO_ROOT" "$git_root" "$fixture" "$actual_head" "$mode" "$checkout_clean" <<'PY'
import copy
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

repo_root = pathlib.Path(sys.argv[1]).resolve()
git_root = pathlib.Path(sys.argv[2])
fixture_path = pathlib.Path(sys.argv[3])
actual_head = sys.argv[4]
mode = sys.argv[5]
checkout_clean = sys.argv[6] == "true"
resolved_git_root = git_root.resolve()
allowed_fixture_root = (repo_root / "infra" / "api" / "tests" / "fixtures").resolve()

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

def resolve_repo_fixture(path: pathlib.Path) -> pathlib.Path:
    resolved = path.resolve()
    try:
        resolved.relative_to(allowed_fixture_root)
    except ValueError:
        action_required(
            "contract fixture path must stay inside infra/api/tests/fixtures"
        )
    return resolved

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

fixture_path = resolve_repo_fixture(fixture_path)
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

def provider_discriminated_routes(payload: dict) -> dict:
    paths = required_object_field(payload, "paths", "OpenAPI artifact")
    status_alias = re.compile(r"^/1/migrations/([^/{]+)/\{job_id\}$")
    providers = sorted(
        match.group(1)
        for path, operations in paths.items()
        if isinstance(path, str)
        and isinstance(operations, dict)
        and "get" in operations
        and (match := status_alias.fullmatch(path)) is not None
    )
    if not providers:
        action_required("OpenAPI artifact contains no source migration provider aliases", exit_code=3)

    shared_routes = {
        "submit": {
            "method": "POST",
            "path": "/1/migrations/{source_provider}",
        },
        "status": {
            "method": "GET",
            "path": "/1/migrations/{source_provider}/{job_id}",
        },
        "cancel": {
            "method": "POST",
            "path": "/1/migrations/{source_provider}/{job_id}/cancel",
        },
        "acknowledge": {
            "method": "POST",
            "path": "/1/migrations/{source_provider}/{job_id}/acknowledge",
        },
        "preview": {
            "method": "POST",
            "path": "/1/migrations/{source_provider}/preview",
        },
    }
    provider_aliases: dict[str, dict[str, str]] = {}
    for provider in providers:
        aliases = {
            role: route["path"].replace("{source_provider}", provider)
            for role, route in shared_routes.items()
        }
        for role, path in aliases.items():
            path_method(payload, path, shared_routes[role]["method"])
            if role == "preview":
                schema_ref = route_response_schema_ref(
                    payload,
                    path,
                    shared_routes[role]["method"],
                    "200",
                )
                if schema_ref != "#/components/schemas/MigrationPreviewResponse":
                    action_required(
                        f"OpenAPI artifact preview route {path} response schema drifted",
                        exit_code=3,
                    )
        provider_aliases[provider] = aliases

    return {
        "provider_discriminator": {
            "field": "source_provider",
            "values": providers,
        },
        "routes": shared_routes,
        "provider_aliases": provider_aliases,
    }

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
    if "responses" in expected:
        if operation.get("operationId") != expected.get("operation_id"):
            action_required("OpenAPI artifact ACK route operationId drifted", exit_code=3)
        security_scheme = expected.get("authentication", {}).get("security_scheme")
        if operation.get("security") != [{security_scheme: []}]:
            action_required("OpenAPI artifact ACK route authentication contract drifted", exit_code=3)
        parameters = operation.get("parameters")
        expected_parameters = expected.get("request", {}).get("path_parameters")
        observed_parameters = [
            parameter.get("name")
            for parameter in parameters
            if isinstance(parameter, dict)
            and parameter.get("in") == "path"
            and parameter.get("required") is True
        ] if isinstance(parameters, list) else []
        if observed_parameters != expected_parameters:
            action_required("OpenAPI artifact ACK route path parameter contract drifted", exit_code=3)
        if expected.get("request", {}).get("body") == "none" and operation.get("requestBody") is not None:
            action_required("OpenAPI artifact ACK route unexpectedly accepts a request body", exit_code=3)
        responses = operation.get("responses", {})
        if not isinstance(responses, dict):
            action_required("OpenAPI artifact ACK route responses are invalid", exit_code=3)
        for response in expected.get("responses", {}).values():
            if not isinstance(response, dict):
                action_required("fixture acknowledgement_contract responses must be objects")
            status = str(response.get("http_status"))
            observed = responses.get(status)
            if not isinstance(observed, dict) or observed.get("description") != response.get("description"):
                action_required(f"OpenAPI artifact ACK route response {status} drifted", exit_code=3)
        return
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

def privacy_scrub_known_answer_config(fixture: dict) -> tuple[list[str], pathlib.Path, str]:
    known_answer = fixture.get("privacy_scrub_known_answer")
    if not isinstance(known_answer, dict):
        action_required("fixture privacy_scrub_known_answer must be an object")
    command = known_answer.get("command")
    working_directory = known_answer.get("working_directory")
    success_marker = known_answer.get("success_marker")
    if (
        not isinstance(command, list)
        or not command
        or any(not isinstance(argument, str) or not argument for argument in command)
        or not isinstance(working_directory, str)
        or not working_directory
        or not isinstance(success_marker, str)
        or not success_marker
    ):
        action_required(
            "fixture privacy_scrub_known_answer must define command, working_directory, and success_marker"
        )
    if command[0] != "bash" or len(command) < 2:
        action_required("engine privacy-scrub known-answer command must be a pinned bash script")
    if re.fullmatch(r"(?:\s*\[PASS\] privacy scrub .+|privacy-scrub .+: PASS)", success_marker) is None:
        action_required(
            "engine privacy-scrub known-answer success marker must identify a privacy-scrub proof"
        )
    workdir_path = pathlib.PurePosixPath(working_directory)
    if workdir_path.is_absolute() or ".." in workdir_path.parts:
        action_required("engine privacy-scrub known-answer working directory must stay inside the engine checkout")
    return command, pathlib.Path(working_directory), success_marker

def require_pinned_known_answer_script(command: list[str], working_directory: pathlib.Path) -> None:
    script_path = pathlib.PurePosixPath(command[1])
    if script_path.is_absolute() or ".." in script_path.parts:
        action_required("engine privacy-scrub known-answer script path must stay inside its working directory")
    for argument in command[2:]:
        argument_path = pathlib.PurePosixPath(argument)
        if argument_path.is_absolute() or ".." in argument_path.parts:
            action_required("engine privacy-scrub known-answer arguments must not contain absolute or parent paths")
    script_file = git_root / working_directory / script_path
    if not script_file.is_file() or script_file.is_symlink():
        action_required("engine privacy-scrub known-answer script is missing", exit_code=3)
    tracked_path = (working_directory / pathlib.Path(command[1])).as_posix()
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", tracked_path],
        cwd=git_root,
        check=False,
        capture_output=True,
        text=True,
    )
    clean = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--", tracked_path],
        cwd=git_root,
        check=False,
    )
    if tracked.returncode != 0 or clean.returncode != 0:
        action_required(
            "engine privacy-scrub known-answer script must be the pinned tracked source",
            exit_code=3,
        )

def run_privacy_scrub_known_answer(fixture: dict) -> None:
    command, working_directory, success_marker = privacy_scrub_known_answer_config(fixture)
    require_pinned_known_answer_script(command, working_directory)
    try:
        completed = subprocess.run(
            command,
            cwd=git_root / working_directory,
            check=False,
            capture_output=True,
            text=True,
            timeout=1200,
        )
    except (OSError, subprocess.TimeoutExpired):
        action_required("engine privacy-scrub known-answer test could not run", exit_code=3)
    output_lines = completed.stdout.splitlines()
    if completed.returncode != 0 or output_lines.count(success_marker) != 1:
        action_required(
            "engine privacy-scrub known-answer test did not prove the pinned receipt semantics",
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

def property_type_descriptor(name: str, field: str, prop: object) -> dict:
    if not isinstance(prop, dict):
        action_required(f"schema {name} property {field} is not an object")
    ptype = prop.get("type")
    if not isinstance(ptype, str):
        action_required(f"schema {name} property {field} is missing a scalar type")
    if ptype == "array":
        items = prop.get("items")
        if not isinstance(items, dict) or not isinstance(items.get("type"), str):
            action_required(f"schema {name} array property {field} is missing an item type")
        return {"type": "array", "items": items["type"]}
    return {"type": ptype}

def observed_property_types(payload: dict, name: str) -> dict:
    properties = schema(payload, name).get("properties", {})
    if not isinstance(properties, dict):
        action_required(f"schema {name} properties are invalid")
    return {
        field: property_type_descriptor(name, field, prop)
        for field, prop in properties.items()
    }

def enum_values(payload: dict, name: str) -> list[str]:
    value = schema(payload, name).get("enum")
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        action_required(f"schema {name} enum is invalid")
    return value

def schema_properties(payload: dict, name: str) -> dict:
    properties = schema(payload, name).get("properties", {})
    if not isinstance(properties, dict):
        action_required(f"schema {name} properties are invalid")
    return properties

def property_schema(payload: dict, name: str, field: str) -> dict:
    properties = schema_properties(payload, name)
    value = properties.get(field)
    if not isinstance(value, dict):
        action_required(f"schema {name} field {field} is missing or invalid", exit_code=3)
    return value

def type_values(value: dict, owner: str) -> list[str]:
    observed = value.get("type")
    if isinstance(observed, str):
        return [observed]
    if isinstance(observed, list) and all(isinstance(item, str) for item in observed):
        return sorted(observed)
    action_required(f"{owner} type is invalid", exit_code=3)

def nullable_ref(value: dict, owner: str) -> dict:
    direct_ref = value.get("$ref")
    if isinstance(direct_ref, str):
        return {"ref": direct_ref, "nullable": False}
    one_of = value.get("oneOf")
    if not isinstance(one_of, list) or len(one_of) != 2:
        action_required(f"{owner} must be a nullable $ref", exit_code=3)
    ref_values = [
        item.get("$ref")
        for item in one_of
        if isinstance(item, dict) and isinstance(item.get("$ref"), str)
    ]
    null_values = [
        item
        for item in one_of
        if isinstance(item, dict) and item.get("type") == "null"
    ]
    if len(ref_values) != 1 or len(null_values) != 1:
        action_required(
            f"{owner} must contain exactly one null arm and one $ref arm",
            exit_code=3,
        )
    return {"ref": ref_values[0], "nullable": True}

def array_items_ref(value: dict, owner: str) -> dict:
    if value.get("type") != "array":
        action_required(f"{owner} must be an array", exit_code=3)
    items = value.get("items")
    if not isinstance(items, dict) or not isinstance(items.get("$ref"), str):
        action_required(f"{owner} array items must be a $ref", exit_code=3)
    return {"type": "array", "items_ref": items["$ref"]}

def schema_ref(value: object, owner: str) -> str:
    if not isinstance(value, dict) or not isinstance(value.get("$ref"), str):
        action_required(f"{owner} must be a $ref", exit_code=3)
    return value["$ref"]

def route_response_schema_ref(payload: dict, path: str, method: str, status: str) -> str:
    paths = required_object_field(payload, "paths", "OpenAPI artifact")
    path_value = required_object_field(paths, path, "OpenAPI artifact paths")
    operation = required_object_field(
        path_value,
        method.lower(),
        f"OpenAPI artifact path {path}",
    )
    responses = required_object_field(
        operation,
        "responses",
        f"OpenAPI artifact {method.upper()} {path}",
    )
    response = required_object_field(
        responses,
        status,
        f"OpenAPI artifact {method.upper()} {path} responses",
    )
    response_schema = (
        response
        .get("content", {})
        .get("application/json", {})
        .get("schema")
    )
    return schema_ref(
        response_schema,
        f"OpenAPI artifact {method.upper()} {path} HTTP {status} response schema",
    )

def route_request_schema_ref(payload: dict, path: str, method: str) -> str:
    paths = required_object_field(payload, "paths", "OpenAPI artifact")
    path_value = required_object_field(paths, path, "OpenAPI artifact paths")
    operation = required_object_field(
        path_value,
        method.lower(),
        f"OpenAPI artifact path {path}",
    )
    request_schema = (
        operation
        .get("requestBody", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema")
    )
    return schema_ref(
        request_schema,
        f"OpenAPI artifact {method.upper()} {path} request schema",
    )

def component_schema_name(ref: str, owner: str) -> str:
    prefix = "#/components/schemas/"
    if not ref.startswith(prefix) or len(ref) == len(prefix):
        action_required(f"{owner} must reference a component schema", exit_code=3)
    return ref.removeprefix(prefix)

def schema_ref_property(payload: dict, name: str, field: str) -> str:
    return schema_ref(
        property_schema(payload, name, field),
        f"schema {name} field {field}",
    )

def preview_report_entry_contract(payload: dict) -> dict:
    field_types: dict[str, list[str]] = {}
    refs: dict[str, str] = {}
    for field, value in sorted(schema_properties(payload, "MigrationPreviewReportEntry").items()):
        if field in {"code", "resource", "severity"}:
            refs[field] = schema_ref(value, f"schema MigrationPreviewReportEntry field {field}")
        else:
            field_types[field] = type_values(
                value,
                f"schema MigrationPreviewReportEntry field {field}",
            )
    return {
        "required_fields": sorted_required(payload, "MigrationPreviewReportEntry"),
        "optional_fields": sorted_optional(payload, "MigrationPreviewReportEntry"),
        "field_types": field_types,
        "refs": refs,
    }

def runtime_preview_support(provider_aliases: dict) -> dict[str, bool]:
    source_path = "engine/flapjack-http/src/handlers/migration/mod.rs"
    source = subprocess.run(
        ["git", "show", f"{actual_head}:{source_path}"],
        cwd=git_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if source.returncode != 0:
        action_required(
            f"could not read supports_preview owner at {actual_head}:{source_path}",
            exit_code=3,
        )
    supports_preview = re.search(
        r"fn\s+supports_preview\s*\(\s*&self\s*\)\s*->\s*bool\s*"
        r"\{\s*matches!\(\s*self\s*,(?P<variants>.*?)\)\s*\}",
        source.stdout,
        flags=re.DOTALL,
    )
    if supports_preview is None:
        action_required("could not derive runtime preview support from supports_preview", exit_code=3)

    provider_variants = {
        provider: "".join(part.capitalize() for part in provider.split("_"))
        for provider in provider_aliases
    }
    supported_variants = set(
        re.findall(r"Self::([A-Za-z][A-Za-z0-9_]*)", supports_preview.group("variants"))
    )
    unknown_variants = supported_variants - set(provider_variants.values())
    if unknown_variants:
        action_required(
            "supports_preview contains providers outside the OpenAPI closed union: "
            + ", ".join(sorted(unknown_variants)),
            exit_code=3,
        )
    return {
        provider: variant in supported_variants
        for provider, variant in sorted(provider_variants.items())
    }

def preview_contract(payload: dict, provider_aliases: dict) -> dict:
    request_schema_refs = {
        provider: route_request_schema_ref(payload, aliases["preview"], "POST")
        for provider, aliases in sorted(provider_aliases.items())
    }
    return {
        "runtime_preview_support": runtime_preview_support(provider_aliases),
        "request_schema_refs": request_schema_refs,
        "request_fields": {
            provider: {
                "required_fields": sorted_required(
                    payload,
                    component_schema_name(ref, f"{provider} preview request"),
                ),
                "optional_fields": sorted_optional(
                    payload,
                    component_schema_name(ref, f"{provider} preview request"),
                ),
            }
            for provider, ref in request_schema_refs.items()
        },
        "response": {
            "required_fields": sorted_required(payload, "MigrationPreviewResponse"),
            "optional_fields": sorted_optional(payload, "MigrationPreviewResponse"),
            "report_ref": schema_ref_property(
                payload,
                "MigrationPreviewResponse",
                "report",
            ),
            "source_counts_ref": schema_ref_property(
                payload,
                "MigrationPreviewResponse",
                "sourceCounts",
            ),
        },
        "source_counts": {
            "required_fields": sorted_required(payload, "MigrationPreviewSourceCounts"),
            "optional_fields": sorted_optional(payload, "MigrationPreviewSourceCounts"),
            "field_types": field_type_map(payload, "MigrationPreviewSourceCounts"),
        },
        "report": {
            "required_fields": sorted_required(payload, "MigrationPreviewReport"),
            "optional_fields": sorted_optional(payload, "MigrationPreviewReport"),
            "entries": array_items_ref(
                property_schema(payload, "MigrationPreviewReport", "entries"),
                "schema MigrationPreviewReport field entries",
            ),
            "summary_ref": schema_ref_property(
                payload,
                "MigrationPreviewReport",
                "summary",
            ),
            "reportDigest": {
                "type": type_values(
                    property_schema(payload, "MigrationPreviewReport", "reportDigest"),
                    "schema MigrationPreviewReport field reportDigest",
                ),
            },
        },
        "report_summary": {
            "required_fields": sorted_required(payload, "MigrationPreviewReportSummary"),
            "optional_fields": sorted_optional(payload, "MigrationPreviewReportSummary"),
            "field_types": field_type_map(payload, "MigrationPreviewReportSummary"),
        },
        "report_entry": preview_report_entry_contract(payload),
        "enums": {
            "code": enum_values(payload, "ReportCode"),
            "resource": enum_values(payload, "ReportResource"),
            "severity": enum_values(payload, "ReportSeverity"),
        },
    }

def field_type_map(payload: dict, name: str) -> dict:
    return {
        field: type_values(value, f"schema {name} field {field}")
        for field, value in sorted(schema_properties(payload, name).items())
    }

def status_outcome_contract(payload: dict) -> dict:
    return {
        "fields": [
            "rulesImported",
            "settingsApplied",
            "synonymsImported",
            "warnings",
        ],
        "settingsApplied": {
            "type": type_values(
                property_schema(payload, "AsyncMigrationStatusResponse", "settingsApplied"),
                "schema AsyncMigrationStatusResponse field settingsApplied",
            ),
        },
        "synonymsImported": nullable_ref(
            property_schema(payload, "AsyncMigrationStatusResponse", "synonymsImported"),
            "schema AsyncMigrationStatusResponse field synonymsImported",
        ),
        "rulesImported": nullable_ref(
            property_schema(payload, "AsyncMigrationStatusResponse", "rulesImported"),
            "schema AsyncMigrationStatusResponse field rulesImported",
        ),
        "warnings": array_items_ref(
            property_schema(payload, "AsyncMigrationStatusResponse", "warnings"),
            "schema AsyncMigrationStatusResponse field warnings",
        ),
    }

def carried_status_outcome_contract(payload: dict, fixture: dict) -> dict:
    status_properties = schema_properties(payload, "AsyncMigrationStatusResponse")
    outcome_fields = [
        "rulesImported",
        "settingsApplied",
        "synonymsImported",
        "warnings",
    ]
    present = [field for field in outcome_fields if field in status_properties]
    if present and present != outcome_fields:
        action_required(
            "OpenAPI artifact publishes only a partial terminal outcome extension",
            exit_code=3,
        )
    if present:
        return {
            "status_outcome": status_outcome_contract(payload),
            "count": {
                "required_fields": sorted_required(payload, "MigrateCount"),
                "optional_fields": sorted_optional(payload, "MigrateCount"),
                "field_types": field_type_map(payload, "MigrateCount"),
            },
            "warning": {
                "required_fields": sorted_required(payload, "MigrateWarning"),
                "optional_fields": sorted_optional(payload, "MigrateWarning"),
                "field_types": field_type_map(payload, "MigrateWarning"),
            },
        }
    return {
        key: copy.deepcopy(required_object_field(fixture, key, "fixture"))
        for key in ["status_outcome", "count", "warning"]
    }

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

def validate_privacy_scrub_contract(fixture: dict, payload: dict) -> None:
    expected = fixture.get("privacy_scrub_contract")
    if not isinstance(expected, dict):
        action_required("fixture privacy_scrub_contract must be an object")
    route = expected.get("route")
    if not isinstance(route, dict):
        action_required("fixture privacy_scrub_contract.route must be an object")
    path = route.get("path")
    method = route.get("method")
    if not isinstance(path, str) or not isinstance(method, str):
        action_required("fixture privacy_scrub_contract.route must define method and path")
    paths = required_object_field(payload, "paths", "OpenAPI artifact")
    path_value = paths.get(path)
    operation = path_value.get(method.lower()) if isinstance(path_value, dict) else None
    if not isinstance(operation, dict):
        action_required(f"OpenAPI artifact is missing privacy scrub route {method} {path}", exit_code=3)
    if operation.get("operationId") != route.get("operation_id"):
        action_required("OpenAPI artifact privacy scrub operationId drifted", exit_code=3)
    security_scheme = route.get("security_scheme")
    if operation.get("security") != [{security_scheme: []}]:
        action_required("OpenAPI artifact privacy scrub authentication contract drifted", exit_code=3)
    body_ref = (
        operation.get("requestBody", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if body_ref != "#/components/schemas/PrivacyScrubRequest":
        action_required("OpenAPI artifact privacy scrub request schema drifted", exit_code=3)
    ack = expected.get("ack", {})
    responses = operation.get("responses", {})
    ack_status = str(ack.get("http_status"))
    ack_ref = (
        responses.get(ack_status, {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if ack_ref != f"#/components/schemas/{ack.get('schema')}":
        action_required("OpenAPI artifact privacy scrub ACK response schema drifted", exit_code=3)
    if sorted_required(payload, "PrivacyScrubRequest") != expected.get("request", {}).get("required_fields"):
        action_required("OpenAPI artifact privacy scrub request required fields drifted", exit_code=3)
    if sorted_optional(payload, "PrivacyScrubRequest") != expected.get("request", {}).get("optional_fields"):
        action_required("OpenAPI artifact privacy scrub request optional fields drifted", exit_code=3)
    if sorted_required(payload, "PrivacyScrubAck") != ack.get("required_fields"):
        action_required("OpenAPI artifact privacy scrub ACK required fields drifted", exit_code=3)
    if sorted_optional(payload, "PrivacyScrubAck") != ack.get("optional_fields"):
        action_required("OpenAPI artifact privacy scrub ACK optional fields drifted", exit_code=3)
    request_property_types = expected.get("request", {}).get("property_types")
    if not isinstance(request_property_types, dict) or not request_property_types:
        action_required("fixture privacy_scrub_contract.request.property_types must be a nonempty object")
    if observed_property_types(payload, "PrivacyScrubRequest") != request_property_types:
        action_required("OpenAPI artifact privacy scrub request property types drifted", exit_code=3)
    ack_property_types = ack.get("property_types")
    if not isinstance(ack_property_types, dict) or not ack_property_types:
        action_required("fixture privacy_scrub_contract.ack.property_types must be a nonempty object")
    if observed_property_types(payload, "PrivacyScrubAck") != ack_property_types:
        action_required("OpenAPI artifact privacy scrub ACK property types drifted", exit_code=3)

def validate_privacy_scrub_receipt(fixture: dict) -> None:
    receipt = fixture.get("privacy_scrub_contract", {}).get("receipt")
    if not isinstance(receipt, dict):
        action_required("fixture privacy_scrub_contract.receipt must be an object")
    rel_path = receipt.get("path")
    if not isinstance(rel_path, str):
        action_required("fixture privacy scrub receipt path must be a string")
    receipt_path = pathlib.PurePosixPath(rel_path)
    if receipt_path.is_absolute() or ".." in receipt_path.parts:
        action_required("engine privacy scrub receipt path must stay inside the engine checkout")
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", rel_path],
        cwd=git_root,
        check=False,
        capture_output=True,
        text=True,
    )
    clean = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--", rel_path],
        cwd=git_root,
        check=False,
    )
    if tracked.returncode != 0 or clean.returncode != 0:
        action_required("engine privacy scrub receipt must be the pinned tracked source", exit_code=3)
    payload = load_json(resolve_checkout_artifact(rel_path))
    if payload.get("receipt_type") != "privacy_scrub_transport":
        action_required("engine privacy scrub receipt type drifted", exit_code=3)
    for key in ["validated_head_sha", "scrub_implementation_sha"]:
        if payload.get(key) != receipt.get(key):
            action_required(f"engine privacy scrub receipt {key} drifted", exit_code=3)
    validated_head_sha = receipt.get("validated_head_sha")
    if (
        not isinstance(validated_head_sha, str)
        or re.fullmatch(r"[0-9a-f]{40}", validated_head_sha) is None
    ):
        action_required(
            "engine privacy scrub receipt validated_head_sha must be a 40-character commit SHA",
            exit_code=3,
        )
    commit_exists = subprocess.run(
        ["git", "cat-file", "-e", f"{validated_head_sha}^{{commit}}"],
        cwd=git_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if commit_exists.returncode != 0:
        action_required(
            "engine privacy scrub receipt validated_head_sha is missing from the pinned checkout",
            exit_code=3,
        )
    target_head = actual_head if mode == "update" else pinned_engine_sha
    reachable = subprocess.run(
        ["git", "merge-base", "--is-ancestor", validated_head_sha, target_head],
        cwd=git_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if reachable.returncode != 0:
        action_required(
            "engine privacy scrub receipt validated_head_sha is not reachable from the pinned checkout",
            exit_code=3,
        )
    variants = payload.get("denominators", {}).get("boundary_variants", {}).get("variants")
    if variants != receipt.get("boundary_variants"):
        action_required("engine privacy scrub receipt boundary variants drifted", exit_code=3)
    auth_cases = payload.get("denominators", {}).get("auth_negative_cases", {}).get("cases")
    if auth_cases != receipt.get("auth_negative_cases"):
        action_required("engine privacy scrub receipt auth negative cases drifted", exit_code=3)
    resource_classes = payload.get("denominators", {}).get("exact_absence_resource_classes", {}).get("classes")
    if resource_classes != receipt.get("exact_absence_resource_classes"):
        action_required("engine privacy scrub receipt exact-absence classes drifted", exit_code=3)

def extract_contract(payload: dict, fixture: dict) -> dict:
    path_method(payload, "/1/migrations/algolia", "POST")
    path_method(payload, "/1/migrations/algolia/{job_id}", "GET")
    path_method(payload, "/1/migrations/algolia/{job_id}/cancel", "POST")
    path_method(payload, "/1/migrations/privacy-scrub", "POST")
    carried_outcome = carried_status_outcome_contract(payload, fixture)
    status_optional = sorted_optional(payload, "AsyncMigrationStatusResponse")
    for field in carried_outcome["status_outcome"]["fields"]:
        if field not in status_optional:
            status_optional.append(field)
    status_optional.sort()
    provider_contract = provider_discriminated_routes(payload)
    return {
        **provider_contract,
        "request": {
            "required_fields": sorted_required(payload, "MigrateFromAlgoliaRequest"),
            "optional_fields": sorted_optional(payload, "MigrateFromAlgoliaRequest"),
        },
        "status": {
            "required_fields": sorted_required(payload, "AsyncMigrationStatusResponse"),
            "optional_fields": status_optional,
        },
        "status_outcome": carried_outcome["status_outcome"],
        "count": carried_outcome["count"],
        "warning": carried_outcome["warning"],
        "progress": {
            "required_fields": sorted_required(payload, "AsyncMigrationExportProgress"),
            "optional_fields": sorted_optional(payload, "AsyncMigrationExportProgress"),
        },
        "preview": preview_contract(payload, provider_contract["provider_aliases"]),
        "enums": {
            "phase": enum_values(payload, "AsyncMigrationPhase"),
            "disposition": enum_values(payload, "AsyncMigrationDisposition"),
        },
        "errors": response_codes(payload),
    }

fixture_artifacts = fixture.get("openapi_artifacts")
if not isinstance(fixture_artifacts, list) or not fixture_artifacts:
    action_required("fixture openapi_artifacts must be a nonempty list")

contract_keys = [
    "provider_discriminator",
    "routes",
    "provider_aliases",
    "request",
    "status",
    "status_outcome",
    "count",
    "warning",
    "progress",
    "preview",
    "enums",
    "errors",
]
provider_metadata_keys = {"provider_discriminator", "provider_aliases"}
accepted_status_optional_growth = {
    "objectsImported",
    "operation",
    "resumable",
    "resumeHandle",
    "targetIndex",
    "topology",
}
missing_contract_keys = [key for key in contract_keys if key not in fixture]
if mode == "check" and missing_contract_keys:
    action_required(
        f"fixture is missing normalized contract keys: {', '.join(missing_contract_keys)}"
    )
provider_contract_upgrade = mode == "update" and any(
    key in missing_contract_keys
    for key in ["provider_discriminator", "provider_aliases"]
)

def string_values(value: object, owner: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        action_required(f"{owner} must be a list of strings")
    return value

def is_provider_metadata_widening(extracted: dict) -> bool:
    if mode != "update" or not provider_metadata_keys.issubset(fixture):
        return False
    current_discriminator = required_object_field(
        fixture,
        "provider_discriminator",
        "fixture",
    )
    extracted_discriminator = required_object_field(
        extracted,
        "provider_discriminator",
        "generated contract",
    )
    if (
        current_discriminator == extracted_discriminator
        and fixture["provider_aliases"] == extracted["provider_aliases"]
    ):
        return False
    if current_discriminator.get("field") != extracted_discriminator.get("field"):
        return False

    current_values = string_values(
        current_discriminator.get("values"),
        "fixture provider_discriminator values",
    )
    extracted_values = string_values(
        extracted_discriminator.get("values"),
        "generated provider_discriminator values",
    )
    current_value_set = set(current_values)
    extracted_value_set = set(extracted_values)
    if not current_value_set < extracted_value_set:
        return False

    current_aliases = required_object_field(fixture, "provider_aliases", "fixture")
    extracted_aliases = required_object_field(
        extracted,
        "provider_aliases",
        "generated contract",
    )
    if set(current_aliases) - current_value_set:
        return False
    for provider in current_values:
        current_provider_aliases = required_object_field(
            current_aliases,
            provider,
            "fixture provider_aliases",
        )
        extracted_provider_aliases = required_object_field(
            extracted_aliases,
            provider,
            "generated provider_aliases",
        )
        if any(
            extracted_provider_aliases.get(role) != path
            for role, path in current_provider_aliases.items()
        ):
            return False
    return True

def is_preview_route_widening(extracted: dict) -> bool:
    if mode != "update" or "routes" not in fixture or "provider_aliases" not in fixture:
        return False
    if "preview" in fixture:
        return False
    current_routes = required_object_field(fixture, "routes", "fixture")
    extracted_routes = required_object_field(extracted, "routes", "generated contract")
    if "preview" in current_routes:
        return False
    expected_routes = copy.deepcopy(current_routes)
    expected_routes["preview"] = {
        "method": "POST",
        "path": "/1/migrations/{source_provider}/preview",
    }
    routes_match = expected_routes == extracted_routes
    if not routes_match:
        return False

    current_aliases = required_object_field(fixture, "provider_aliases", "fixture")
    extracted_aliases = required_object_field(
        extracted,
        "provider_aliases",
        "generated contract",
    )
    if set(current_aliases) != set(extracted_aliases):
        return False
    for provider, aliases in current_aliases.items():
        if not isinstance(provider, str):
            return False
        current_provider_aliases = required_object_field(
            current_aliases,
            provider,
            "fixture provider_aliases",
        )
        extracted_provider_aliases = required_object_field(
            extracted_aliases,
            provider,
            "generated provider_aliases",
        )
        expected_aliases = copy.deepcopy(current_provider_aliases)
        expected_aliases.setdefault("preview", f"/1/migrations/{provider}/preview")
        if extracted_provider_aliases != expected_aliases:
            return False
    return True

def is_preview_request_schema_ref_pin(extracted: dict) -> bool:
    if mode != "update" or "preview" not in fixture:
        return False
    current_preview = required_object_field(fixture, "preview", "fixture")
    if "request_schema_refs" in current_preview:
        return False
    extracted_preview = required_object_field(extracted, "preview", "generated contract")
    expected_preview = copy.deepcopy(current_preview)
    request_schema_refs = extracted_preview.get("request_schema_refs")
    if not isinstance(request_schema_refs, dict) or not request_schema_refs:
        return False
    expected_preview["request_schema_refs"] = request_schema_refs
    return extracted_preview == expected_preview

def is_preview_request_schema_ref_widening(extracted: dict) -> bool:
    if mode != "update" or "preview" not in fixture:
        return False
    current_preview = required_object_field(fixture, "preview", "fixture")
    extracted_preview = required_object_field(extracted, "preview", "generated contract")
    current_refs = current_preview.get("request_schema_refs")
    extracted_refs = extracted_preview.get("request_schema_refs")
    if not isinstance(current_refs, dict) or not isinstance(extracted_refs, dict):
        return False
    if not set(current_refs) < set(extracted_refs):
        return False
    for provider, schema_ref in current_refs.items():
        if extracted_refs.get(provider) != schema_ref:
            return False
    current_fields = current_preview.get("request_fields")
    extracted_fields = extracted_preview.get("request_fields")
    if not isinstance(current_fields, dict) or not isinstance(extracted_fields, dict):
        return False
    if set(extracted_fields) != set(extracted_refs):
        return False
    for provider, fields in current_fields.items():
        if extracted_fields.get(provider) != fields:
            return False
    expected_preview = copy.deepcopy(current_preview)
    expected_preview["request_schema_refs"] = extracted_refs
    expected_preview["request_fields"] = extracted_fields
    return extracted_preview == expected_preview

def is_preview_request_fields_pin(extracted: dict) -> bool:
    if mode != "update" or "preview" not in fixture:
        return False
    current_preview = required_object_field(fixture, "preview", "fixture")
    if "request_fields" in current_preview:
        return False
    extracted_preview = required_object_field(extracted, "preview", "generated contract")
    request_fields = extracted_preview.get("request_fields")
    if not isinstance(request_fields, dict) or not request_fields:
        return False
    expected_preview = copy.deepcopy(current_preview)
    expected_preview["request_fields"] = request_fields
    return extracted_preview == expected_preview

def is_preview_runtime_support_pin(extracted: dict) -> bool:
    if mode != "update" or "preview" not in fixture:
        return False
    current_preview = required_object_field(fixture, "preview", "fixture")
    if "runtime_preview_support" in current_preview:
        return False
    extracted_preview = required_object_field(extracted, "preview", "generated contract")
    runtime_support = extracted_preview.get("runtime_preview_support")
    if not isinstance(runtime_support, dict) or not runtime_support:
        return False
    expected_preview = copy.deepcopy(current_preview)
    expected_preview["runtime_preview_support"] = runtime_support
    return extracted_preview == expected_preview


def is_accepted_status_optional_widening(extracted: dict) -> bool:
    if mode != "update" or "status" not in fixture:
        return False
    current_status = required_object_field(fixture, "status", "fixture")
    extracted_status = required_object_field(extracted, "status", "generated contract")
    if current_status.get("required_fields") != extracted_status.get("required_fields"):
        return False
    current_optional = string_values(
        current_status.get("optional_fields"),
        "fixture status optional_fields",
    )
    extracted_optional = string_values(
        extracted_status.get("optional_fields"),
        "generated status optional_fields",
    )
    current_optional_set = set(current_optional)
    extracted_optional_set = set(extracted_optional)
    added = extracted_optional_set - current_optional_set
    return (
        current_optional_set < extracted_optional_set
        and added <= accepted_status_optional_growth
        and current_optional == sorted(current_optional)
        and extracted_optional == sorted(extracted_optional)
    )

def comparable_fixture_contract(extracted: dict) -> dict:
    ignored_keys: set[str] = set()
    if provider_contract_upgrade:
        ignored_keys.update(provider_metadata_keys)
        ignored_keys.add("routes")
    elif is_provider_metadata_widening(extracted):
        ignored_keys.update(provider_metadata_keys)
        if is_preview_request_schema_ref_widening(extracted):
            ignored_keys.add("preview")
    if is_preview_route_widening(extracted):
        ignored_keys.update({"routes", "provider_aliases", "preview"})
    elif is_preview_request_schema_ref_pin(extracted):
        ignored_keys.add("preview")
    elif is_preview_request_fields_pin(extracted):
        ignored_keys.add("preview")
    elif is_preview_runtime_support_pin(extracted):
        ignored_keys.add("preview")
    if is_accepted_status_optional_widening(extracted):
        ignored_keys.add("status")
    return {
        key: copy.deepcopy(required_object_field(fixture, key, "fixture"))
        for key in contract_keys
        if key in fixture and key not in ignored_keys
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
    validate_privacy_scrub_contract(fixture, artifact_payload)
    extracted = extract_contract(artifact_payload, fixture)
    expected_without_meta = comparable_fixture_contract(extracted)
    extracted_existing_contract = {
        key: extracted[key]
        for key in expected_without_meta
    }
    if extracted_existing_contract != expected_without_meta:
        action_required(f"OpenAPI artifact {rel_path} normalized contract differs from fixture")
    if baseline_contract is None:
        baseline_contract = extracted
    elif extracted != baseline_contract:
        action_required(f"OpenAPI artifact {rel_path} normalized contract differs from first artifact", exit_code=3)

validate_privacy_scrub_receipt(fixture)
run_privacy_scrub_known_answer(fixture)

if not checkout_clean:
    action_required("flapjack checkout must be clean before contract validation")

if mode == "update":
    updated = copy.deepcopy(fixture)
    if baseline_contract is None:
        action_required("no OpenAPI artifacts were normalized for update")
    for key in contract_keys:
        updated[key] = baseline_contract[key]
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
