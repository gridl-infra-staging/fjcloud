#!/usr/bin/env python3
"""Wave 3 phase receipt writer/validator.

Receipts are cleanup-safe resume pointers only. They bind one Wave 3 phase to
the frozen base SHA, explicit file inventories and digests, the phase exit
code, and the selected arm. Validation restores those values after proving the
receipt still matches its owner-managed anchor and current lane bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Iterable


PHASE_RECEIPTS = {
    "preflight": "preflight_pass.json",
    "section1": "section1_pass.json",
    "rc": "rc_pass.json",
}

SHA_RE = re.compile(r"[0-9a-f]{40}")
GROUP_RE = re.compile(r"[A-Za-z0-9_]+")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    write_parser = add_common_parser(subparsers, "write")
    write_parser.add_argument("--exit-code", required=True, type=int)
    write_parser.add_argument("--selected-arm", required=True)

    validate_parser = add_common_parser(subparsers, "validate")
    validate_parser.add_argument("--lane-copy", action="append", default=[])
    return parser.parse_args(argv)


def add_common_parser(
    subparsers: argparse._SubParsersAction[argparse.ArgumentParser],
    name: str,
) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(name)
    parser.add_argument("--lane-root", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--phase", required=True, choices=sorted(PHASE_RECEIPTS))
    parser.add_argument("--inventory", action="append", default=[])
    return parser


def require_base_sha(value: str) -> str:
    if not SHA_RE.fullmatch(value):
        fail(f"--base-sha must be a 40-character lowercase hex SHA, got: {value}")
    return value


def resolve_lane_root(raw: str) -> Path:
    lane_root = Path(raw).resolve()
    if not lane_root.is_dir():
        fail(f"lane root is not a directory: {raw}")
    return lane_root


def receipt_path(lane_root: Path, base_sha: str, phase: str) -> Path:
    return receipt_root(lane_root, base_sha) / PHASE_RECEIPTS[phase]


def receipt_anchor_path(path: Path) -> Path:
    return path.with_name(f"{path.name}.sha256")


def receipt_root(lane_root: Path, base_sha: str) -> Path:
    return lane_root / "tmp" / f"jul13_wave3_phases_{base_sha}"


def is_relative_to(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def reject_symlink_components(lane_root: Path, path: Path, label: str) -> None:
    try:
        relative = path.relative_to(lane_root)
    except ValueError:
        fail(f"{label} escapes lane root: {path}")
    current = lane_root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            fail(f"symlink components are not allowed in {label}: {path}")


def resolve_receipt_path(lane_root: Path, base_sha: str, phase: str) -> Path:
    path = receipt_path(lane_root, base_sha, phase)
    if not is_relative_to(path.resolve(strict=False), lane_root):
        fail(f"receipt path escapes lane root: {path}")
    reject_symlink_components(lane_root, path, "receipt path")
    return path


def safe_relative_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        fail(f"absolute paths are not allowed in inventories: {raw}")
    if ".." in path.parts:
        fail(f"parent traversal is not allowed in inventories: {raw}")
    if not path.parts:
        fail("empty inventory path")
    return path


def resolve_lane_file(lane_root: Path, raw: str) -> Path:
    rel_path = safe_relative_path(raw)
    path = lane_root / rel_path
    resolved = path.resolve()
    if not is_relative_to(resolved, lane_root):
        fail(f"inventory path escapes lane root: {raw}")
    reject_symlink_components(lane_root, path, "inventory path")
    if not resolved.is_file():
        fail(f"inventory file not found: {raw}")
    return resolved


def parse_inventory_spec(spec: str) -> tuple[str, str, str | None]:
    if "=" not in spec:
        fail(f"inventory entries must be group=relative/path, got: {spec}")
    group, raw_path = spec.split("=", 1)
    if not GROUP_RE.fullmatch(group):
        fail(f"inventory group must use alphanumeric characters or underscores: {group}")
    path, expected_digest = parse_expected_inventory_digest(raw_path)
    return group, path, expected_digest


def parse_expected_inventory_digest(raw_path: str) -> tuple[str, str | None]:
    marker = "@sha256:"
    if marker not in raw_path:
        return raw_path, None
    path, digest = raw_path.rsplit(marker, 1)
    if not path:
        fail(f"inventory path is empty before {marker}")
    if not DIGEST_RE.fullmatch(digest):
        fail(f"expected inventory digest must be a SHA-256 hex string: {raw_path}")
    return path, digest


def reject_owner_managed_inventory_path(rel_path: Path, base_sha: str) -> None:
    managed_root = Path("tmp") / f"jul13_wave3_phases_{base_sha}"
    if rel_path == managed_root or managed_root in rel_path.parents:
        fail(f"inventory path is under owner-managed receipt root: {rel_path.as_posix()}")


def build_inventory(
    lane_root: Path,
    base_sha: str,
    specs: Iterable[str],
) -> dict[str, list[dict[str, object]]]:
    inventories: dict[str, list[dict[str, object]]] = {}
    seen_paths: set[str] = set()
    for spec in specs:
        group, raw_path, expected_digest = parse_inventory_spec(spec)
        rel_path = safe_relative_path(raw_path)
        reject_owner_managed_inventory_path(rel_path, base_sha)
        normalized = rel_path.as_posix()
        if normalized in seen_paths:
            fail(f"duplicate inventory path: {normalized}")
        seen_paths.add(normalized)
        data = resolve_lane_file(lane_root, normalized).read_bytes()
        actual_digest = sha256_bytes(data)
        if expected_digest is not None and actual_digest != expected_digest:
            fail(f"current file digest mismatch for inventory path: {normalized}")
        inventories.setdefault(group, []).append(
            {
                "path": normalized,
                "size": len(data),
                "sha256": actual_digest,
            }
        )
    if not inventories:
        fail("at least one --inventory entry is required")
    return {group: sorted(entries, key=lambda item: str(item["path"]))
            for group, entries in sorted(inventories.items())}


def inventory_digest(inventories: dict[str, list[dict[str, object]]]) -> str:
    return sha256_bytes(canonical_json_bytes(inventories))


def receipt_digest(receipt: dict[str, object]) -> str:
    return sha256_bytes(canonical_json_bytes({
        "schema_version": receipt["schema_version"],
        "phase": receipt["phase"],
        "sha": receipt["sha"],
        "exit_code": receipt["exit_code"],
        "selected_arm": receipt["selected_arm"],
        "inventories": receipt["inventories"],
        "inventory_digest": receipt["inventory_digest"],
        "cleanup_authorization": receipt["cleanup_authorization"],
    }))


def atomic_write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f"{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(tmp_fd, "w") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def atomic_write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f"{path.name}.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(tmp_fd, "w") as handle:
            handle.write(payload)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def write_receipt(args: argparse.Namespace) -> int:
    base_sha = require_base_sha(args.base_sha)
    lane_root = resolve_lane_root(args.lane_root)
    if not args.selected_arm:
        fail("--selected-arm must not be empty")
    inventories = build_inventory(lane_root, base_sha, args.inventory)
    payload = {
        "schema_version": 1,
        "phase": args.phase,
        "sha": base_sha,
        "exit_code": args.exit_code,
        "selected_arm": args.selected_arm,
        "inventories": inventories,
        "inventory_digest": inventory_digest(inventories),
        "cleanup_authorization": "exact-inventory-only",
    }
    payload["receipt_digest"] = receipt_digest(payload)
    path = resolve_receipt_path(lane_root, base_sha, args.phase)
    atomic_write_json(path, payload)
    atomic_write_text(receipt_anchor_path(path), f"{payload['receipt_digest']}\n")
    print(path)
    return 0


def load_receipt(path: Path) -> dict[str, object]:
    if not path.is_file():
        fail(f"receipt not found: {path}")
    try:
        receipt = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"receipt is not valid JSON: {exc}")
    if not isinstance(receipt, dict):
        fail("receipt root must be a JSON object")
    return receipt


def validate_receipt_shape(receipt: dict[str, object], base_sha: str, phase: str) -> None:
    if receipt.get("schema_version") != 1:
        fail("schema_version mismatch")
    if receipt.get("phase") != phase:
        fail(f"phase mismatch: receipt has {receipt.get('phase')}, expected {phase}")
    if receipt.get("sha") != base_sha:
        fail(f"sha mismatch: receipt has {receipt.get('sha')}, expected {base_sha}")
    exit_code = receipt.get("exit_code")
    if not isinstance(exit_code, int) or isinstance(exit_code, bool):
        fail("receipt exit_code must be an integer")
    if not isinstance(receipt.get("selected_arm"), str) or not receipt.get("selected_arm"):
        fail("receipt selected_arm must be a non-empty string")
    if receipt.get("cleanup_authorization") != "exact-inventory-only":
        fail("cleanup_authorization mismatch")
    if not isinstance(receipt.get("inventory_digest"), str):
        fail("receipt inventory_digest must be a string")
    if not isinstance(receipt.get("receipt_digest"), str):
        fail("receipt receipt_digest must be a string")


def normalize_receipt_inventories(value: object) -> dict[str, list[dict[str, object]]]:
    if not isinstance(value, dict):
        fail("receipt inventories must be an object")
    normalized: dict[str, list[dict[str, object]]] = {}
    seen_paths: set[str] = set()
    for group, entries in value.items():
        if not isinstance(group, str) or not GROUP_RE.fullmatch(group):
            fail(f"invalid receipt inventory group: {group}")
        if not isinstance(entries, list):
            fail(f"receipt inventory group must be a list: {group}")
        normalized[group] = [normalize_receipt_entry(entry, seen_paths) for entry in entries]
        normalized[group].sort(key=lambda item: str(item["path"]))
    return {group: normalized[group] for group in sorted(normalized)}


def normalize_receipt_entry(entry: object, seen_paths: set[str]) -> dict[str, object]:
    if not isinstance(entry, dict):
        fail("receipt inventory entries must be objects")
    path = entry.get("path")
    size = entry.get("size")
    digest = entry.get("sha256")
    if not isinstance(path, str):
        fail("receipt inventory path must be a string")
    safe_relative_path(path)
    if path in seen_paths:
        fail(f"duplicate inventory path: {path}")
    seen_paths.add(path)
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        fail(f"receipt inventory size is invalid for {path}")
    if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
        fail(f"receipt inventory digest is invalid for {path}")
    return {"path": path, "size": size, "sha256": digest}


def validate_inventory(
    receipt: dict[str, object],
    lane_root: Path,
    base_sha: str,
    expected: dict[str, list[dict[str, object]]] | None,
) -> dict[str, list[dict[str, object]]]:
    actual = normalize_receipt_inventories(receipt.get("inventories"))
    if not actual:
        fail("receipt inventories must not be empty")
    if expected is not None:
        if inventory_paths(actual) != inventory_paths(expected):
            fail("inventory mismatch between receipt and explicit --inventory entries")
        for group, entries in expected.items():
            actual_by_path = {str(entry["path"]): entry for entry in actual[group]}
            for expected_entry in entries:
                path = str(expected_entry["path"])
                if actual_by_path[path] != expected_entry:
                    fail(f"digest mismatch for inventory path: {path}")
    validate_current_inventory_bytes(lane_root, base_sha, actual)
    if receipt.get("inventory_digest") != inventory_digest(actual):
        fail("inventory_digest mismatch")
    return actual


def validate_current_inventory_bytes(
    lane_root: Path,
    base_sha: str,
    inventories: dict[str, list[dict[str, object]]],
) -> None:
    for entries in inventories.values():
        for entry in entries:
            normalized = str(entry["path"])
            rel_path = safe_relative_path(normalized)
            reject_owner_managed_inventory_path(rel_path, base_sha)
            data = resolve_lane_file(lane_root, normalized).read_bytes()
            if sha256_bytes(data) != entry["sha256"]:
                fail(f"current file digest mismatch for inventory path: {normalized}")
            if len(data) != entry["size"]:
                fail(f"current file size mismatch for inventory path: {normalized}")


def validate_receipt_digest(receipt: dict[str, object]) -> None:
    actual = receipt.get("receipt_digest")
    if not isinstance(actual, str) or not DIGEST_RE.fullmatch(actual):
        fail("receipt_digest is invalid")
    if actual != receipt_digest(receipt):
        fail("receipt_digest mismatch")


def validate_receipt_anchor(lane_root: Path, path: Path, receipt: dict[str, object]) -> None:
    anchor_path = receipt_anchor_path(path)
    reject_symlink_components(lane_root, anchor_path, "receipt anchor path")
    if not anchor_path.is_file():
        fail(f"receipt anchor missing: {anchor_path}")
    anchor = anchor_path.read_text().strip()
    if not DIGEST_RE.fullmatch(anchor):
        fail("receipt anchor is invalid")
    if anchor != receipt["receipt_digest"]:
        fail("receipt anchor mismatch")


def inventory_paths(inventories: dict[str, list[dict[str, object]]]) -> dict[str, list[str]]:
    return {
        group: [str(entry["path"]) for entry in entries]
        for group, entries in inventories.items()
    }


def parse_lane_copy(spec: str) -> tuple[str, str]:
    if ":" not in spec:
        fail(f"--lane-copy must be source:copy, got: {spec}")
    source, copy = spec.split(":", 1)
    return safe_relative_path(source).as_posix(), safe_relative_path(copy).as_posix()


def validate_lane_copies(lane_root: Path, specs: Iterable[str]) -> None:
    for spec in specs:
        source_raw, copy_raw = parse_lane_copy(spec)
        source = resolve_lane_file(lane_root, source_raw)
        copy = resolve_lane_file(lane_root, copy_raw)
        if source.read_bytes() != copy.read_bytes():
            fail(f"lane copy byte drift: {source_raw} != {copy_raw}")


def validate_receipt(args: argparse.Namespace) -> int:
    base_sha = require_base_sha(args.base_sha)
    lane_root = resolve_lane_root(args.lane_root)
    path = resolve_receipt_path(lane_root, base_sha, args.phase)
    receipt = load_receipt(path)
    validate_receipt_shape(receipt, base_sha, args.phase)
    validate_lane_copies(lane_root, args.lane_copy)
    expected = build_inventory(lane_root, base_sha, args.inventory) if args.inventory else None
    inventories = validate_inventory(receipt, lane_root, base_sha, expected)
    validate_receipt_digest(receipt)
    validate_receipt_anchor(lane_root, path, receipt)
    print(json.dumps({
        "phase": args.phase,
        "sha": base_sha,
        "exit_code": receipt["exit_code"],
        "selected_arm": receipt["selected_arm"],
        "inventories": inventories,
        "inventory_digest": receipt["inventory_digest"],
        "cleanup_authorized": True,
    }, sort_keys=True))
    return 0


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.command == "write":
        return write_receipt(args)
    if args.command == "validate":
        return validate_receipt(args)
    fail(f"unexpected command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
