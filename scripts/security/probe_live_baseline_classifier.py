#!/usr/bin/env python3
"""Classify fixture-compatible live-baseline evidence into row verdicts."""

import json
import re
import sys
from pathlib import Path

EVIDENCE_DIR = Path(sys.argv[1])
FLEET_ROWS = [
    "fleet_tls_443",
    "public_tcp_7700_ingress",
    "engine_admin_surface",
    "engine_auth_enforcement",
    "engine_health_disclosure",
]
SPF_BASELINE_TOKENS = ("include:amazonses.com", "include:_spf.google.com", "~all")
DMARC_BASELINE_POLICY = "p=none"
HEALTH_FIELDS = {
    "version",
    "git_revision",
    "workspace_digest",
    "loaded_tenant_count",
    "memory_bytes",
}
PUBLIC_IPV4_CIDR = "0.0.0.0/0"
PUBLIC_IPV6_CIDR = "::/0"


class Result:
    def __init__(self, verdict, detail):
        self.verdict = verdict
        self.detail = detail


def read_text(path):
    """Return normalized UTF-8 evidence, or None when it cannot be read."""
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return None


def numeric_text(value):
    return bool(re.fullmatch(r"[0-9]+", value or ""))


def status_is_http(value):
    return bool(re.fullmatch(r"[1-5][0-9][0-9]", value or ""))


def clean_dns_record(value):
    value = " ".join(value.strip().split())
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    value = value.replace('" "', "")
    match = re.search(r'descriptive text "([^"]+)"', value)
    if match:
        value = match.group(1)
    return value


def collection_exit(prefix):
    exit_path = EVIDENCE_DIR / f"{prefix}.exit"
    if not exit_path.exists():
        return None, "missing_evidence"
    exit_text = read_text(exit_path)
    if not numeric_text(exit_text):
        return None, "unparseable"
    if int(exit_text) != 0:
        return int(exit_text), "collection_failed"
    return 0, ""


def read_status(prefix, evidence):
    status_path = EVIDENCE_DIR / f"{prefix}.status"
    exit_path = EVIDENCE_DIR / f"{prefix}.exit"
    if not exit_path.exists():
        return None, Result("UNMEASURABLE", f"evidence={evidence} reason=missing_evidence")
    if not status_path.exists():
        return None, Result("UNMEASURABLE", f"evidence={evidence} reason=missing_evidence")
    status = read_text(status_path)
    exit_text = read_text(exit_path)
    if not numeric_text(exit_text):
        return None, Result("UNMEASURABLE", f"evidence={evidence} reason=unparseable")
    exit_value = int(exit_text)
    if exit_value != 0:
        if status == "000" and exit_value in {7, 28}:
            return None, Result("UNMEASURABLE", f"evidence={evidence} reason=unreachable_is_not_posture")
        return None, Result("UNMEASURABLE", f"evidence={evidence} reason=collection_failed exit={exit_value}")
    if not status_is_http(status):
        return None, Result("UNMEASURABLE", f"evidence={evidence} reason=unparseable")
    return status, None


def target_key(target):
    return f"{target['environment']}_{target['instance_id']}"


def parse_targets():
    exit_path = EVIDENCE_DIR / "targets.exit"
    error_path = EVIDENCE_DIR / "targets.error"
    if not exit_path.exists():
        return None, "missing_evidence"
    exit_text = read_text(exit_path)
    if not numeric_text(exit_text):
        return None, "unparseable"
    if int(exit_text) != 0:
        error_text = (read_text(error_path) if error_path.exists() else "") or ""
        if "AccessDenied" in error_text:
            return None, "AccessDenied"
        return None, f"collection_failed exit={int(exit_text)}"

    target_path = EVIDENCE_DIR / "targets.tsv"
    if not target_path.exists():
        return None, "missing_evidence"
    target_text = read_text(target_path)
    if target_text is None:
        return None, "unparseable"
    targets = []
    for line in target_text.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 4 or not all(fields):
            return None, "unparseable"
        targets.append({
            "environment": fields[0],
            "instance_id": fields[1],
            "address": fields[2],
            "sg_ids": fields[3],
        })
    return targets, ""


def combine_required_results(results):
    """Fail closed across required measurements, citing the deciding one.

    UNMEASURABLE short-circuits because an unmeasured input cannot be argued
    away by other measurements; DRIFT outranks MATCH; and an all-MATCH set
    cites its last measurement so the row still reports evidence that was
    actually read rather than a synthesized placeholder. Callers must pass at
    least one result.
    """
    drift = None
    last = None
    for current in results:
        if current.verdict == "UNMEASURABLE":
            return current
        if current.verdict == "DRIFT":
            drift = current
        last = current
    return drift or last


def aggregate(targets, classifier):
    return combine_required_results(classifier(target) for target in targets)


def http_reached_target(target, path_key):
    key = target_key(target)
    status_path = EVIDENCE_DIR / f"{key}.http_{path_key}.status"
    exit_path = EVIDENCE_DIR / f"{key}.http_{path_key}.exit"
    if not status_path.exists() or not exit_path.exists():
        return False
    status = read_text(status_path)
    exit_text = read_text(exit_path)
    return status_is_http(status) and numeric_text(exit_text) and int(exit_text) == 0


def target_was_reached(target):
    return any(
        http_reached_target(target, path_key)
        for path_key in ("dashboard", "swagger_ui", "indexes", "health")
    )


def classify_tls_target(target):
    key = target_key(target)
    evidence = f"https://{target['address']}:443"
    status_path = EVIDENCE_DIR / f"{key}.tls.status"
    verify_path = EVIDENCE_DIR / f"{key}.tls.verify"
    exit_path = EVIDENCE_DIR / f"{key}.tls.exit"
    if not status_path.exists() or not verify_path.exists() or not exit_path.exists():
        return Result("UNMEASURABLE", f"evidence={evidence} reason=missing_evidence")
    status = read_text(status_path)
    exit_text = read_text(exit_path)
    verify_text = read_text(verify_path)
    if not numeric_text(exit_text) or not numeric_text(verify_text):
        return Result("UNMEASURABLE", f"evidence={evidence} reason=unparseable")
    if not status_is_http(status) and status != "000":
        return Result("UNMEASURABLE", f"evidence={evidence} reason=unparseable")

    exit_value = int(exit_text)
    verify_value = int(verify_text)
    if exit_value == 0 and verify_value == 0 and status_is_http(status):
        return Result("DRIFT", f"evidence={evidence} expected=tls_absent actual=tls_present_verified")
    if verify_value != 0 or exit_value in {35, 51, 60}:
        return Result("DRIFT", f"evidence={evidence} expected=tls_absent actual=tls_present_untrusted")
    if status == "000" and exit_value == 7:
        if not target_was_reached(target):
            return Result("UNMEASURABLE", f"evidence={evidence} reason=unreachable_is_not_posture")
        return Result("MATCH", f"evidence={evidence} expected=tls_absent actual=tls_absent")
    if exit_value != 0:
        return Result("UNMEASURABLE", f"evidence={evidence} reason=collection_failed exit={exit_value}")
    return Result("UNMEASURABLE", f"evidence={evidence} reason=unparseable")


def public_7700_cidr(payload, expected_groups):
    """Return the public CIDR that exposes tcp/7700, or None when none does."""
    groups = payload.get("SecurityGroups") if isinstance(payload, dict) else None
    if (
        not isinstance(groups, list)
        or not groups
        or not all(isinstance(group, dict) for group in groups)
    ):
        raise ValueError("bad groups")
    returned = {group.get("GroupId") for group in groups}
    if returned != set(expected_groups):
        raise ValueError("wrong groups")
    for group in groups:
        permissions = group.get("IpPermissions")
        if not isinstance(permissions, list):
            raise ValueError("bad permissions")
        for permission in permissions:
            if not isinstance(permission, dict):
                raise ValueError("bad permission")
            protocol = permission.get("IpProtocol")
            if protocol not in {"tcp", "-1"}:
                continue
            if protocol == "tcp":
                start = permission.get("FromPort")
                end = permission.get("ToPort")
                if not isinstance(start, int) or not isinstance(end, int):
                    raise ValueError("bad ports")
                if not start <= 7700 <= end:
                    continue
            ipv4_ranges = permission.get("IpRanges", [])
            ipv6_ranges = permission.get("Ipv6Ranges", [])
            if not isinstance(ipv4_ranges, list) or not isinstance(ipv6_ranges, list):
                raise ValueError("bad ranges")
            if has_public_cidr(ipv4_ranges, "CidrIp", PUBLIC_IPV4_CIDR):
                return PUBLIC_IPV4_CIDR
            if has_public_cidr(ipv6_ranges, "CidrIpv6", PUBLIC_IPV6_CIDR):
                return PUBLIC_IPV6_CIDR
    return None


def has_public_cidr(ranges, cidr_key, public_cidr):
    return any(
        isinstance(item, dict) and item.get(cidr_key) == public_cidr
        for item in ranges
    )


def classify_sg_target(target):
    key = target_key(target)
    first_sg = target["sg_ids"].split(",", 1)[0]
    evidence = f"{first_sg} tcp/7700"
    exit_value, error = collection_exit(f"{key}.sg")
    if error:
        detail = f"evidence={evidence} reason={error}"
        if exit_value is not None:
            detail += f" exit={exit_value}"
        return Result("UNMEASURABLE", detail)
    json_path = EVIDENCE_DIR / f"{key}.sg.json"
    if not json_path.exists():
        return Result("UNMEASURABLE", f"evidence={evidence} reason=missing_evidence")
    try:
        payload = json.loads(read_text(json_path))
        matched_cidr = public_7700_cidr(payload, target["sg_ids"].split(","))
    except (TypeError, ValueError):
        return Result("UNMEASURABLE", f"evidence={evidence} reason=unparseable")
    # `expected` is the recorded baseline CIDR; `actual` must name the CIDR that
    # was measured, which is ::/0 on an IPv6-only public rule.
    expectation = f"expected=public_{PUBLIC_IPV4_CIDR}"
    if matched_cidr:
        return Result("MATCH", f"evidence={evidence} {expectation} actual=public_{matched_cidr}")
    return Result("DRIFT", f"evidence={evidence} {expectation} actual=not_public")


def classify_http_target(target, path_key, request_path, expected_status):
    key = target_key(target)
    evidence = request_path
    status, error = read_status(f"{key}.http_{path_key}", evidence)
    if error:
        return error
    if status == expected_status:
        return Result("MATCH", f"evidence={evidence} expected={expected_status} actual={status}")
    return Result("DRIFT", f"evidence={evidence} expected={expected_status} actual={status}")


def classify_admin_target(target):
    dashboard = classify_http_target(target, "dashboard", "/dashboard", "404")
    swagger = classify_http_target(target, "swagger_ui", "/swagger-ui", "404")
    return combine_required_results((dashboard, swagger))


def classify_health_target(target):
    key = target_key(target)
    status = classify_http_target(target, "health", "/health", "200")
    if status.verdict != "MATCH":
        return status
    body_path = EVIDENCE_DIR / f"{key}.http_health.body"
    if not body_path.exists():
        return Result("UNMEASURABLE", "evidence=/health reason=missing_evidence")
    try:
        payload = json.loads(read_text(body_path))
    except (TypeError, ValueError):
        return Result("UNMEASURABLE", "evidence=/health reason=unparseable")
    if not isinstance(payload, dict):
        return Result("UNMEASURABLE", "evidence=/health reason=unparseable")
    if HEALTH_FIELDS.issubset(payload):
        return Result("MATCH", "evidence=/health expected=disclosure_fields_present actual=disclosure_fields_present")
    return Result("DRIFT", "evidence=/health expected=disclosure_fields_present actual=disclosure_fields_absent")


def read_txt_records(output_path):
    output = read_text(output_path)
    if output is None:
        return None
    return [
        clean_dns_record(line)
        for line in output.splitlines()
        if line.strip()
    ]


def select_txt_record(records, prefix):
    return next((item for item in records if item.lower().startswith(prefix)), None)


def classify_spf_record(record):
    lower = record.lower()
    baseline = all(token in lower for token in SPF_BASELINE_TOKENS)
    return record, "MATCH" if baseline else "DRIFT"


def classify_dmarc_record(record):
    policy = re.search(r"(?:^|;)\s*p\s*=\s*([^;\s]+)", record.lower())
    actual = f"p={policy.group(1)}" if policy else "p=missing"
    return actual, "MATCH" if actual == DMARC_BASELINE_POLICY else "DRIFT"


# Declared here rather than with the other constants because each row binds the
# record comparison defined above. This is the single source for the DNS rows.
DNS_ROW_SPECS = {
    "spf": {
        "name": "flapjack.foo",
        "prefix": "v=spf1",
        "expected": "amazonses_and_google",
        "classify_record": classify_spf_record,
    },
    "dmarc": {
        "name": "_dmarc.flapjack.foo",
        "prefix": "v=dmarc1",
        "expected": DMARC_BASELINE_POLICY,
        "classify_record": classify_dmarc_record,
    },
}
DNS_ROWS = list(DNS_ROW_SPECS)
ROW_ORDER = FLEET_ROWS + DNS_ROWS


def classify_dns(row_id):
    spec = DNS_ROW_SPECS[row_id]
    name = spec["name"]
    output_path = EVIDENCE_DIR / f"dns_{row_id}.output"
    exit_value, error = collection_exit(f"dns_{row_id}")
    if error:
        detail = f"evidence={name} reason={error}"
        if exit_value is not None:
            detail += f" exit={exit_value}"
        return Result("UNMEASURABLE", detail)
    if not output_path.exists():
        return Result("UNMEASURABLE", f"evidence={name} reason=missing_evidence")

    expectation = f"expected={spec['expected']}"
    records = read_txt_records(output_path)
    if records is None:
        return Result("UNMEASURABLE", f"evidence={name} reason=unparseable")
    if not records:
        # `dig +short TXT` and `host -t TXT` both exit 0 with an empty answer for
        # a name that has no TXT record, so a successful empty collection is a
        # measured deletion rather than a failed measurement.
        return Result("DRIFT", f"evidence={name} {expectation} actual=record_absent")
    record = select_txt_record(records, spec["prefix"])
    if record is None:
        return Result("UNMEASURABLE", f"evidence={name} reason=unparseable")
    actual, verdict = spec["classify_record"](record)
    return Result(verdict, f"evidence={name} {expectation} actual={actual}")


def summary_verdict(counts, vacuous):
    if vacuous:
        return "VACUOUS"
    if counts["UNMEASURABLE"]:
        return "UNMEASURABLE"
    if counts["DRIFT"]:
        return "DRIFT"
    return "MATCH"


def emit_row(row_id, result):
    print(f"ROW id={row_id} verdict={result.verdict} {result.detail}")


def main():
    targets, fleet_error = parse_targets()
    results = {}
    diagnostic = None
    if targets is None:
        diagnostic = Result("UNMEASURABLE", f"evidence=aws_ec2_describe_instances reason={fleet_error}")
        for row_id in FLEET_ROWS:
            results[row_id] = Result("UNMEASURABLE", f"evidence=aws_ec2_describe_instances reason={fleet_error}")
    elif targets:
        results["fleet_tls_443"] = aggregate(targets, classify_tls_target)
        results["public_tcp_7700_ingress"] = aggregate(targets, classify_sg_target)
        results["engine_admin_surface"] = aggregate(targets, classify_admin_target)
        results["engine_auth_enforcement"] = aggregate(
            targets,
            lambda target: classify_http_target(target, "indexes", "/1/indexes", "403"),
        )
        results["engine_health_disclosure"] = aggregate(targets, classify_health_target)

    for row_id in DNS_ROWS:
        results[row_id] = classify_dns(row_id)

    if diagnostic:
        emit_row("fleet_inventory", diagnostic)

    counts = {"MATCH": 0, "DRIFT": 0, "UNMEASURABLE": 0}
    for row_id in ROW_ORDER:
        if row_id not in results:
            continue
        emit_row(row_id, results[row_id])
        counts[results[row_id].verdict] += 1

    checked = sum(counts.values())
    vacuous = targets == [] if targets is not None else False
    verdict = summary_verdict(counts, vacuous)
    print(
        "SUMMARY "
        f"checked={checked} match={counts['MATCH']} drift={counts['DRIFT']} "
        f"unmeasurable={counts['UNMEASURABLE']} verdict={verdict}"
    )
    return 0 if verdict == "MATCH" else 1


if __name__ == "__main__":
    raise SystemExit(main())
