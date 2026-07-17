#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from email import policy
from email.parser import BytesParser
from pathlib import Path

AUTH_FAILURE_EXIT_CODE = 22
USAGE_EXIT_CODE = 2
RUNTIME_EXIT_CODE = 1
REQUIRED_COMPONENTS = ("dkim", "spf", "dmarc")
VERDICT_PATTERN = re.compile(r"\b(dkim|spf|dmarc)\s*=\s*([a-zA-Z]+)", re.IGNORECASE)


def _emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, sort_keys=True))


# TODO: Document _load_rfc822.
def _load_rfc822(path: Path) -> bytes:
    return path.read_bytes()


# TODO: Document _extract_component_verdicts.
def _extract_component_verdicts(authentication_results_headers: list[str]) -> dict[str, str]:
    verdicts: dict[str, str] = {component: "missing" for component in REQUIRED_COMPONENTS}
    for header_value in authentication_results_headers:
        for component, verdict in VERDICT_PATTERN.findall(header_value):
            normalized_component = component.lower()
            normalized_verdict = verdict.lower()
            if verdicts[normalized_component] == "missing":
                verdicts[normalized_component] = normalized_verdict
    return verdicts


# TODO: Document _build_detail.
def _build_detail(verdicts: dict[str, str], failed_components: list[str]) -> str:
    if not failed_components:
        return "Authentication-Results has dkim=pass, spf=pass, dmarc=pass."

    component_details = [f"{component}={verdicts[component]}" for component in failed_components]
    return "Authentication-Results failed for: " + ", ".join(component_details)


# TODO: Document main.
def main() -> int:
    if len(sys.argv) != 2:
        print("usage: parse_inbound_auth_headers.py <rfc822_path>", file=sys.stderr)
        return USAGE_EXIT_CODE

    rfc822_path = Path(sys.argv[1])
    try:
        raw_message = _load_rfc822(rfc822_path)
    except OSError as exc:
        print(f"error reading RFC822 file {rfc822_path}: {exc}", file=sys.stderr)
        return RUNTIME_EXIT_CODE

    try:
        email_message = BytesParser(policy=policy.default).parsebytes(raw_message)
    except Exception as exc:  # pragma: no cover - defensive parse failure branch
        print(f"error parsing RFC822 payload: {exc}", file=sys.stderr)
        return RUNTIME_EXIT_CODE

    auth_headers = [str(value) for value in email_message.get_all("Authentication-Results", [])]
    verdicts = _extract_component_verdicts(auth_headers)
    failed_components = [component for component in REQUIRED_COMPONENTS if verdicts.get(component) != "pass"]

    payload = {
        "passed": len(failed_components) == 0,
        "dkim": verdicts["dkim"],
        "spf": verdicts["spf"],
        "dmarc": verdicts["dmarc"],
        "failed_components": failed_components,
        "failed_components_csv": ",".join(failed_components),
        "detail": _build_detail(verdicts, failed_components),
    }
    _emit(payload)

    if failed_components:
        return AUTH_FAILURE_EXIT_CODE
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
