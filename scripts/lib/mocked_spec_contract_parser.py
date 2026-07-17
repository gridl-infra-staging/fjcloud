#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def parse_mock_payloads(spec_path: Path) -> list[str]:
    content = spec_path.read_text(encoding="utf-8")
    payloads = re.findall(r"data:\s*'([^']+)'", content)
    if len(payloads) < 4:
        raise ValueError(f"expected at least 4 mocked action payloads, found {len(payloads)}")
    return payloads


def parse_shape_keys_from_devalue_array(raw: str) -> list[str]:
    parsed = json.loads(raw)
    if not isinstance(parsed, list) or not parsed or not isinstance(parsed[0], dict):
        raise ValueError("devalue payload does not begin with shape-map object")
    return sorted(str(key) for key in parsed[0].keys())


def parse_action_shape_keys(response_path: Path) -> list[str]:
    response = json.loads(response_path.read_text(encoding="utf-8"))
    if not isinstance(response, dict):
        raise ValueError("action response is not a JSON object")
    data_field = response.get("data")
    if not isinstance(data_field, str):
        raise ValueError("action response .data is not a string")
    return parse_shape_keys_from_devalue_array(data_field)


def parse_action_recovery_value(response_path: Path) -> str:
    response = json.loads(response_path.read_text(encoding="utf-8"))
    if not isinstance(response, dict):
        raise ValueError("action response is not a JSON object")
    data_field = response.get("data")
    if not isinstance(data_field, str):
        raise ValueError("action response .data is not a string")
    parsed = json.loads(data_field)
    if not isinstance(parsed, list):
        raise ValueError("action response devalue payload is not an array")
    if len(parsed) <= 3 or not isinstance(parsed[3], str):
        raise ValueError("action response missing recoveryAction value slot")
    return parsed[3]


def fixture_fields(fixture_path: Path) -> list[str]:
    lines = fixture_path.read_text(encoding="utf-8").splitlines()
    type_start = None
    for idx, line in enumerate(lines):
        if "export type UpgradeTestFixtureState = {" in line:
            type_start = idx
            break
    if type_start is None:
        raise ValueError("could not locate UpgradeTestFixtureState type")

    depth = 0
    fields: list[str] = []
    for line in lines[type_start:]:
        depth += line.count("{")
        if depth == 1:
            match = re.match(r"^\s*([a-zA-Z_][a-zA-Z0-9_]*)\??:\s*", line)
            if match:
                fields.append(match.group(1))
        depth -= line.count("}")
        if depth <= 0 and line.strip().endswith("};"):
            break

    if not fields:
        raise ValueError("UpgradeTestFixtureState type has no fields")
    return sorted(set(fields))


def fixture_statuses(fixture_path: Path) -> list[str]:
    content = fixture_path.read_text(encoding="utf-8")
    statuses = re.findall(r"status:\s*'([^']+)'", content)
    if not statuses:
        raise ValueError("upgrade_outcome union has no status literals")
    return sorted(set(statuses))


def fixture_field_backings(button_path: Path) -> list[str]:
    content = button_path.read_text(encoding="utf-8")
    fields = re.findall(r"fixture\?\.([a-zA-Z_][a-zA-Z0-9_]*)", content)
    if not fields:
        raise ValueError("no fixture field usage found in UpgradeButton.svelte")
    return sorted(set(fields))


def button_statuses(button_path: Path) -> list[str]:
    content = button_path.read_text(encoding="utf-8")
    statuses = re.findall(r"effectiveUpgradeOutcome\?\.status\s*===\s*'([^']+)'", content)
    if not statuses:
        raise ValueError("no effectiveUpgradeOutcome status checks found")
    return sorted(set(statuses))


def contains_all_tokens(path: Path, tokens: list[str]) -> list[str]:
    content = path.read_text(encoding="utf-8")
    return [token for token in tokens if token not in content]


def extract_function_body(content: str, function_name: str) -> str:
    start_match = re.search(rf"function\s+{re.escape(function_name)}\s*\([^)]*\)\s*\{{", content)
    if not start_match:
        raise ValueError(f"function {function_name} not found")
    i = start_match.end() - 1
    depth = 0
    for idx in range(i, len(content)):
        char = content[idx]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return content[i + 1 : idx]
    raise ValueError(f"function {function_name} has unbalanced braces")


def extract_fail_object_keys(content: str, function_name: str) -> list[str]:
    function_body = extract_function_body(content, function_name)
    fail_match = re.search(r"fail\([^,]+,\s*\{(.*?)\}\s*\)", function_body, re.S)
    if not fail_match:
        raise ValueError(f"function {function_name} has no fail(..., {{...}}) payload")
    object_body = fail_match.group(1)
    keys: list[str] = []
    for raw_line in object_body.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        explicit = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*:", line)
        if explicit:
            keys.append(explicit.group(1))
            continue
        shorthand = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*,?$", line)
        if shorthand:
            keys.append(shorthand.group(1))
    if not keys:
        raise ValueError(f"function {function_name} fail payload has no fields")
    return sorted(set(keys))


def cmd_mock_shape_keys(args: argparse.Namespace) -> int:
    payloads = parse_mock_payloads(Path(args.spec))
    try:
        payload_index = int(args.index)
    except ValueError:
        return fail("index must be an integer")
    if payload_index < 0 or payload_index >= len(payloads):
        return fail(f"index {payload_index} is out of range for {len(payloads)} payloads")
    keys = parse_shape_keys_from_devalue_array(payloads[payload_index])
    print("\n".join(keys))
    return 0


def cmd_action_shape_keys(args: argparse.Namespace) -> int:
    keys = parse_action_shape_keys(Path(args.response))
    print("\n".join(keys))
    return 0


def cmd_action_recovery_value(args: argparse.Namespace) -> int:
    print(parse_action_recovery_value(Path(args.response)))
    return 0


def cmd_fixture_fields(args: argparse.Namespace) -> int:
    print("\n".join(fixture_fields(Path(args.fixture))))
    return 0


def cmd_fixture_statuses(args: argparse.Namespace) -> int:
    print("\n".join(fixture_statuses(Path(args.fixture))))
    return 0


def cmd_fixture_field_backings(args: argparse.Namespace) -> int:
    print("\n".join(fixture_field_backings(Path(args.button))))
    return 0


def cmd_button_statuses(args: argparse.Namespace) -> int:
    print("\n".join(button_statuses(Path(args.button))))
    return 0


def cmd_missing_tokens(args: argparse.Namespace) -> int:
    missing = contains_all_tokens(Path(args.path), args.token)
    if missing:
        print("\n".join(missing))
        return 1
    return 0


def cmd_fail_function_keys(args: argparse.Namespace) -> int:
    content = Path(args.path).read_text(encoding="utf-8")
    print("\n".join(extract_fail_object_keys(content, args.function)))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    mock_shape = subparsers.add_parser("mock-shape-keys")
    mock_shape.add_argument("--spec", required=True)
    mock_shape.add_argument("--index", required=True)
    mock_shape.set_defaults(func=cmd_mock_shape_keys)

    action_shape = subparsers.add_parser("action-shape-keys")
    action_shape.add_argument("--response", required=True)
    action_shape.set_defaults(func=cmd_action_shape_keys)

    recovery_value = subparsers.add_parser("action-recovery-value")
    recovery_value.add_argument("--response", required=True)
    recovery_value.set_defaults(func=cmd_action_recovery_value)

    fixture_field_cmd = subparsers.add_parser("fixture-fields")
    fixture_field_cmd.add_argument("--fixture", required=True)
    fixture_field_cmd.set_defaults(func=cmd_fixture_fields)

    fixture_status_cmd = subparsers.add_parser("fixture-statuses")
    fixture_status_cmd.add_argument("--fixture", required=True)
    fixture_status_cmd.set_defaults(func=cmd_fixture_statuses)

    backing_cmd = subparsers.add_parser("fixture-field-backings")
    backing_cmd.add_argument("--button", required=True)
    backing_cmd.set_defaults(func=cmd_fixture_field_backings)

    button_status_cmd = subparsers.add_parser("button-statuses")
    button_status_cmd.add_argument("--button", required=True)
    button_status_cmd.set_defaults(func=cmd_button_statuses)

    missing_tokens_cmd = subparsers.add_parser("missing-tokens")
    missing_tokens_cmd.add_argument("--path", required=True)
    missing_tokens_cmd.add_argument("--token", action="append", required=True)
    missing_tokens_cmd.set_defaults(func=cmd_missing_tokens)

    fail_keys_cmd = subparsers.add_parser("fail-function-keys")
    fail_keys_cmd.add_argument("--path", required=True)
    fail_keys_cmd.add_argument("--function", required=True)
    fail_keys_cmd.set_defaults(func=cmd_fail_function_keys)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return fail(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
