#!/usr/bin/env python3
"""Fail-closed anti-drift validator for the Wave 3 launch closeout receipt."""

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from ses_coverage_a1_integrity import EXPECTED as EXPECTED_SECTION1_PROBES


FLAG_NAMES = (
    "closeout",
    "launch",
    "roadmap",
    "matrix",
    "iam-validation",
    "section1-manifest",
    "section1-validation",
    "rc-verdict",
    "rc-validation",
)
COMMITTED_ROOTS = {
    "IAM": Path("docs/runbooks/evidence/ses-iam-read"),
    "Section 1": Path("docs/runbooks/evidence/ses-coverage-a1"),
    "RC": Path("docs/runbooks/evidence/invite-ready-rc"),
}
IAM_FIELDS = (
    "account_id",
    "profile_name",
    "bound_role_name",
    "onhost_role_arn_sanitized",
)
IAM_APIS = {
    "DescribeLogGroups": "describe_log_groups",
    "FilterLogEvents": "filter_log_events",
    "DescribeLogStreams": "describe_log_streams",
    "GetLogEvents": "get_log_events",
}
STATUS_OWNER_MARKERS = {
    "launch": ("### ", "jul13_iam", "Wave 3"),
    "roadmap": ("|", "Public-release completion"),
}
MATRIX_VERDICT_MARKERS = {
    "LAUNCH-READY": ("**Aggregate rule:**",),
    "NOT-READY-on-section-1": ("*pre-authorized-shippable*",),
    "NOT-READY-real-defects": ("**Blocking rule:**",),
}
RC_CLASSIFICATIONS = {
    "env_gap",
    "harness_gap",
    "investigate",
    "mode_skip",
    "other_real",
    "setup_infra",
}
NON_PRODUCT_STATUSES = {
    "external_secret_missing",
    "live_evidence_gap",
    "setup_infra",
    "investigate",
}


class ValidationError(Exception):
    """A closeout contradiction that must fail authorization."""


@dataclass(frozen=True)
class Inputs:
    closeout: Path
    launch: Path
    roadmap: Path
    matrix: Path
    iam_validation: Path
    section1_manifest: Path
    section1_validation: Path
    rc_verdict: Path
    rc_validation: Path


def fail(message: str) -> None:
    raise ValidationError(message)


def parse_args(argv: list[str]) -> Inputs:
    values: dict[str, Path] = {}
    allowed = set(FLAG_NAMES)
    for argument in argv:
        if not argument.startswith("--") or "=" not in argument:
            fail(f"unknown flag syntax: {argument}")
        name, value = argument[2:].split("=", 1)
        if name not in allowed:
            fail(f"unknown flag: --{name}")
        if name in values:
            fail(f"repeated flag: --{name}")
        if not value:
            fail(f"empty value for flag: --{name}")
        values[name] = Path(value)
    missing = [f"--{name}" for name in FLAG_NAMES if name not in values]
    if missing:
        fail(f"missing required flag(s): {', '.join(missing)}")
    return Inputs(**{name.replace("-", "_"): values[name] for name in FLAG_NAMES})


def load_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        fail(f"{label} file not found: {path}")
    try:
        value = json.loads(path.read_bytes())
    except json.JSONDecodeError as error:
        fail(f"{label} contains malformed JSON: {error.msg}")
    except OSError as error:
        fail(f"could not read {label} {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object")
    return value


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_equal(actual: object, expected: object, label: str) -> None:
    if actual != expected:
        fail(f"{label} mismatch: got {actual!r}, expected {expected!r}")


def checkout_root(inputs: Inputs) -> Path:
    root = inputs.launch.parent.resolve()
    expected = {
        "launch": root / "LAUNCH.md",
        "roadmap": root / "ROADMAP.md",
        "matrix": root / "docs/launch_verification_matrix.md",
    }
    for name, path in expected.items():
        if getattr(inputs, name).resolve() != path:
            fail(f"--{name} must point to canonical checkout owner {path}")
    return root


def has_symlink_component(root: Path, relative: Path) -> bool:
    current = root
    for component in relative.parts:
        current /= component
        if current.is_symlink():
            return True
    return False


def committed_path(root: Path, reference: object, label: str) -> Path:
    if not isinstance(reference, str) or not reference:
        fail(f"committed {label} path must be a non-empty string")
    path = Path(reference)
    if path.is_absolute():
        fail(f"committed {label} path must be repo-relative")
    if any(part in {".", ".."} for part in reference.split("/")):
        fail(f"committed {label} path contains forbidden component")
    evidence_label = "RC" if label.startswith("RC ") else label
    expected_root = COMMITTED_ROOTS[evidence_label]
    try:
        path.relative_to(expected_root)
    except ValueError:
        fail(f"committed {label} path must be under {expected_root.as_posix()}")
    if has_symlink_component(root, path):
        fail(f"committed {label} path traverses symlink")
    resolved = root / path
    if not resolved.is_file():
        fail(f"committed {label} file not found: {path.as_posix()}")
    return resolved.resolve()


def evidence_reference(closeout: dict[str, Any], label: str) -> dict[str, Any]:
    key = {"IAM": "iam", "Section 1": "section1", "RC": "rc"}[label]
    evidence = closeout.get("committed_evidence")
    reference = evidence.get(key) if isinstance(evidence, dict) else None
    if not isinstance(reference, dict):
        fail(f"closeout missing committed {label} reference")
    return reference


def validate_committed_evidence(root: Path, closeout: dict[str, Any]) -> dict[str, Path]:
    paths: dict[str, Path] = {}
    for label in COMMITTED_ROOTS:
        reference = evidence_reference(closeout, label)
        path = committed_path(root, reference.get("path"), label)
        require_equal(reference.get("digest"), sha256(path), f"committed {label} digest")
        paths[label] = path
        if label == "RC":
            for artifact in ("summary", "run_receipt"):
                path_key = f"{artifact}_path"
                digest_key = f"{artifact}_digest"
                if path_key not in reference and digest_key not in reference:
                    continue
                if path_key not in reference or digest_key not in reference:
                    fail(f"committed RC {artifact} reference is incomplete")
                artifact_path = committed_path(
                    root, reference[path_key], f"RC {artifact}"
                )
                require_equal(
                    reference[digest_key],
                    sha256(artifact_path),
                    f"committed RC {artifact} digest",
                )
                paths[f"RC {artifact}"] = artifact_path
    return paths


def validate_receipt_paths(closeout: dict[str, Any], inputs: Inputs) -> None:
    validation_paths = closeout.get("validation_paths")
    if not isinstance(validation_paths, dict):
        fail("closeout missing validation_paths")
    pairs = {
        "IAM": ("iam", inputs.iam_validation),
        "Section 1": ("section1", inputs.section1_validation),
        "RC": ("rc", inputs.rc_validation),
    }
    for label, (key, cli_path) in pairs.items():
        cited = validation_paths.get(key)
        if not isinstance(cited, str) or Path(cited).resolve() != cli_path.resolve():
            fail(f"{label} validation path substitution")


def validate_source_paths(closeout: dict[str, Any], inputs: Inputs) -> None:
    source_paths = closeout.get("source_paths")
    if not isinstance(source_paths, dict):
        fail("closeout missing source_paths")
    pairs = {
        "Section 1 manifest": ("section1_manifest", inputs.section1_manifest),
        "RC verdict": ("rc_verdict", inputs.rc_verdict),
    }
    for label, (key, cli_path) in pairs.items():
        cited = source_paths.get(key)
        if not isinstance(cited, str) or Path(cited).resolve() != cli_path.resolve():
            fail(f"{label} path substitution")


def validate_section1(
    closeout: dict[str, Any], manifest: dict[str, Any], receipt: dict[str, Any], digest: str
) -> str:
    require_equal(receipt.get("status"), "validated", "Section 1 validation status")
    require_equal(receipt.get("manifest_digest"), digest, "Section 1 validation manifest digest")
    require_equal(receipt.get("sha"), manifest.get("source_sha"), "Section 1 validation SHA")
    require_equal(receipt.get("billing_month"), manifest.get("billing_month"), "Section 1 billing month")
    require_equal(closeout.get("sha"), manifest.get("source_sha"), "closeout SHA")
    require_equal(closeout.get("billing_month"), manifest.get("billing_month"), "closeout billing month")
    probes = manifest.get("probes")
    if not isinstance(probes, list) or not probes:
        fail("Section 1 manifest probes must be a non-empty list")
    probe_ids = [probe.get("probe_id") for probe in probes if isinstance(probe, dict)]
    if (
        len(probe_ids) != len(EXPECTED_SECTION1_PROBES)
        or set(probe_ids) != set(EXPECTED_SECTION1_PROBES)
    ):
        fail("Section 1 manifest probe inventory contradicts canonical owner")
    green = manifest.get("all_green") is True and all(
        probe.get("pass") is True and probe.get("rc") == 0 for probe in probes
    )
    complete_red = manifest.get("all_green") is False and all(
        probe.get("pass") is False
        and isinstance(probe.get("rc"), int)
        and probe["rc"] != 0
        for probe in probes
    )
    if green:
        return "green"
    if complete_red:
        return "complete_red"
    fail("Section 1 manifest all_green/probe state is neither green nor complete-red")


def iam_status_passed(value: object) -> bool:
    return isinstance(value, str) and value.lower() in {"ok", "pass", "passed", "success"}


def validate_iam_source(
    closeout: dict[str, Any], owner: dict[str, Any], validation: dict[str, Any]
) -> None:
    if not iam_status_passed(validation.get("status")):
        fail(f"IAM validation status is not passed/ok: {validation.get('status')!r}")
    if not iam_status_passed(owner.get("status")):
        fail(f"committed IAM status is not passed/ok: {owner.get('status')!r}")
    identity = closeout.get("iam_identity")
    if not isinstance(identity, dict):
        fail("closeout missing IAM identity binding")
    for field in IAM_FIELDS:
        expected = identity.get(field)
        if not isinstance(expected, str) or not expected:
            fail(f"closeout IAM {field} binding is missing")
        require_equal(validation.get(field), expected, f"IAM {field}")
        require_equal(owner.get(field), expected, f"committed IAM {field}")
    require_equal(validation.get("source_sha"), closeout.get("sha"), "IAM source SHA")
    require_equal(owner.get("source_sha"), closeout.get("sha"), "committed IAM source SHA")
    probes = validation.get("api_probes")
    owner_probes = owner.get("api_probes")
    for display_name, key in IAM_APIS.items():
        if not isinstance(probes, dict) or not iam_status_passed(probes.get(key)):
            fail(f"IAM API {display_name} is not ok/pass")
        if not isinstance(owner_probes, dict) or probes.get(key) != owner_probes.get(key):
            fail(f"IAM API {display_name} contradicts committed owner")


def rc_is_allowed(verdict: dict[str, Any]) -> bool:
    value = verdict.get("verdict")
    pre_authorized = verdict.get("pre_authorized_shape_match")
    return (
        value == "LAUNCH-READY" and pre_authorized is True
    ) or (
        value == "NOT-READY-on-section-1" and pre_authorized is True
    ) or (
        value == "NOT-READY-real-defects" and pre_authorized is False
    )


def validate_rc_classifications(verdict: dict[str, Any]) -> int:
    rows = verdict.get("non_pass_steps")
    if not isinstance(rows, list):
        fail("RC non_pass_steps must be an array")
    names: list[str] = []
    other_real_count = 0
    for row in rows:
        if not isinstance(row, dict):
            fail("RC non-pass step classification must be an object")
        name = row.get("name")
        status = row.get("status")
        reason = row.get("reason")
        section_number = row.get("section")
        classification = row.get("classification")
        if not isinstance(name, str) or not name:
            fail("RC non-pass step name is missing")
        if not isinstance(status, str) or not status:
            fail(f"RC non-pass step {name} status is missing")
        if not isinstance(reason, str):
            fail(f"RC non-pass step {name} reason must be a string")
        if (
            not isinstance(section_number, int)
            or isinstance(section_number, bool)
            or not 1 <= section_number <= 6
        ):
            fail(f"RC non-pass step {name} section is invalid")
        if classification not in RC_CLASSIFICATIONS:
            fail(f"RC non-pass step {name} classification is invalid")
        if classification == "other_real":
            if status in NON_PRODUCT_STATUSES:
                fail(f"RC non-pass step {name} masquerades as a product defect")
            other_real_count += 1
        names.append(name)
    if len(names) != len(set(names)):
        fail("RC non_pass_steps contains duplicate required steps")
    recorded_count = verdict.get("other_real_count")
    if not isinstance(recorded_count, int) or isinstance(recorded_count, bool):
        fail("RC other_real_count must be an integer")
    require_equal(recorded_count, other_real_count, "RC other_real_count")
    return other_real_count


def validate_rc(
    closeout: dict[str, Any],
    verdict: dict[str, Any],
    receipt: dict[str, Any],
    digests: dict[str, str],
    section1_state: str,
) -> None:
    if not rc_is_allowed(verdict):
        fail("RC verdict is not launch-allowed")
    other_real_count = validate_rc_classifications(verdict)
    verdict_value = verdict["verdict"]
    required_section1_state = {
        "LAUNCH-READY": "green",
        "NOT-READY-on-section-1": "complete_red",
    }.get(verdict_value)
    if required_section1_state is not None and section1_state != required_section1_state:
        fail(
            f"RC verdict {verdict_value} contradicts {section1_state} "
            "Section 1 manifest"
        )
    if verdict_value == "NOT-READY-real-defects":
        if verdict.get("summary_required_set_complete") is not True:
            fail("RC required step registry is incomplete")
        if other_real_count == 0:
            fail("RC real-defect verdict has no classified product defect")
    elif other_real_count != 0:
        fail(f"RC verdict {verdict_value} contradicts product-defect rows")
    require_equal(closeout.get("final_verdict"), verdict.get("verdict"), "closeout final verdict")
    require_equal(receipt.get("status"), "validated", "RC validation status")
    require_equal(receipt.get("sha"), closeout.get("sha"), "RC validation SHA")
    require_equal(
        receipt.get("section1_manifest_digest"),
        digests["section1"],
        "RC validation Section 1 manifest digest",
    )
    require_equal(receipt.get("verdict_digest"), digests["rc"], "RC validation verdict digest")
    rc_reference = evidence_reference(closeout, "RC")
    for artifact in ("summary", "run_receipt"):
        digest_key = f"{artifact}_digest"
        if digest_key in rc_reference:
            require_equal(
                receipt.get(digest_key),
                rc_reference[digest_key],
                f"RC validation {artifact} digest",
            )


def section(text: str, heading_prefix: str) -> str:
    lines = text.splitlines()
    start = next((index for index, line in enumerate(lines) if line.startswith(heading_prefix)), None)
    if start is None:
        fail(f"status owner missing section {heading_prefix}")
    end = next(
        (index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")),
        len(lines),
    )
    return "\n".join(lines[start:end])


def canonical_status_lines(
    owner_name: str, authoritative_text: str, verdict: str
) -> list[str]:
    markers = (
        MATRIX_VERDICT_MARKERS[verdict]
        if owner_name == "matrix"
        else STATUS_OWNER_MARKERS[owner_name]
    )
    return [
        line
        for line in authoritative_text.splitlines()
        if all(marker in line for marker in markers)
    ]


def validate_status_owners(
    root: Path, closeout: dict[str, Any], inputs: Inputs
) -> None:
    owners = closeout.get("status_owners")
    if not isinstance(owners, dict):
        fail("closeout missing status_owners")
    specs = {
        "launch": (inputs.launch, "LAUNCH.md", "## STATUS"),
        "roadmap": (inputs.roadmap, "ROADMAP.md", "## Planned"),
        "matrix": (
            inputs.matrix,
            "docs/launch_verification_matrix.md",
            "## Section status",
        ),
    }
    for name, (path, canonical, heading) in specs.items():
        reference = owners.get(name)
        if not isinstance(reference, dict):
            fail(f"closeout missing {name} status owner")
        require_equal(reference.get("path"), canonical, f"{name} status owner path")
        require_equal(reference.get("digest"), sha256(path), f"{name} status owner digest")
        expected_text = reference.get("expected_text")
        if not isinstance(expected_text, str) or closeout.get("final_verdict") not in expected_text:
            fail(f"{name} status owner expected_text does not bind final verdict")
        text = path.read_text()
        authoritative_text = section(text, heading) if heading else text
        if expected_text not in authoritative_text.splitlines():
            fail(f"{name} status owner expected_text must cite a complete line")
        if canonical_status_lines(
            name, authoritative_text, closeout["final_verdict"]
        ) != [expected_text]:
            fail(f"{name} status owner has contradictory lines")
    if root != inputs.launch.parent.resolve():
        fail("status owner checkout root changed during validation")


def validate(inputs: Inputs) -> dict[str, object]:
    root = checkout_root(inputs)
    closeout = load_json(inputs.closeout, "closeout")
    committed = validate_committed_evidence(root, closeout)
    validate_receipt_paths(closeout, inputs)
    validate_source_paths(closeout, inputs)
    iam_owner = load_json(committed["IAM"], "committed IAM owner")
    manifest = load_json(inputs.section1_manifest, "section1-manifest")
    verdict = load_json(inputs.rc_verdict, "rc-verdict")
    iam_validation = load_json(inputs.iam_validation, "iam-validation")
    section1_receipt = load_json(inputs.section1_validation, "section1-validation")
    rc_receipt = load_json(inputs.rc_validation, "rc-validation")
    manifest_digest = sha256(inputs.section1_manifest)
    verdict_digest = sha256(inputs.rc_verdict)
    require_equal(manifest_digest, sha256(committed["Section 1"]), "Section 1 source digest")
    require_equal(verdict_digest, sha256(committed["RC"]), "RC source digest")
    section1_state = validate_section1(
        closeout, manifest, section1_receipt, manifest_digest
    )
    validate_iam_source(closeout, iam_owner, iam_validation)
    validate_rc(
        closeout,
        verdict,
        rc_receipt,
        {"section1": manifest_digest, "rc": verdict_digest},
        section1_state,
    )
    validate_status_owners(root, closeout, inputs)
    return {
        "status": "pass",
        "sha": closeout["sha"],
        "final_verdict": verdict["verdict"],
        "section1_manifest_digest": manifest_digest,
        "rc_verdict_digest": verdict_digest,
        "closeout_path": str(inputs.closeout.resolve()),
    }


def main(argv: list[str]) -> int:
    try:
        payload = validate(parse_args(argv))
    except (ValidationError, OSError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
