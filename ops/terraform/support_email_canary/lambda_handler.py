#!/usr/bin/env python3

from __future__ import annotations

import os
import subprocess
from typing import Dict, Optional

import boto3

CANARY_SCRIPT = "/opt/fjcloud/scripts/canary/support_email_deliverability.sh"
ROUNDTRIP_SCRIPT = "/opt/fjcloud/scripts/validate_inbound_email_roundtrip.sh"


def _is_parameter_not_found_error(error: Exception) -> bool:
    response = getattr(error, "response", None)
    if not isinstance(response, dict):
        return False
    details = response.get("Error")
    if not isinstance(details, dict):
        return False
    return str(details.get("Code", "")) == "ParameterNotFound"


def _resolve_webhook_value(raw_value: str, ssm_client) -> str:
    value = raw_value.strip()
    if not value:
        return ""
    if value.startswith("/"):
        try:
            response = ssm_client.get_parameter(Name=value, WithDecryption=True)
        except Exception as error:
            if _is_parameter_not_found_error(error):
                print(f"[WARN] optional webhook parameter {value} is missing; continuing without webhook.")
            else:
                print(
                    f"[WARN] optional webhook parameter {value} could not be resolved; "
                    f"continuing without webhook: {error}"
                )
            return ""
        return str(response["Parameter"]["Value"])
    return value


def _hydrate_webhook_env() -> None:
    region = os.getenv("SES_REGION") or os.getenv("AWS_REGION")
    if not region:
        return

    ssm_client = boto3.client("ssm", region_name=region)
    for env_name in ("SLACK_WEBHOOK_URL", "DISCORD_WEBHOOK_URL"):
        raw = os.getenv(env_name, "")
        if not raw:
            continue
        os.environ[env_name] = _resolve_webhook_value(raw, ssm_client)


def _run_canary() -> Dict[str, object]:
    completed = subprocess.run(
        [CANARY_SCRIPT],
        check=False,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )

    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="")

    result: Dict[str, object] = {
        "support_email_deliverability_script": CANARY_SCRIPT,
        "validate_inbound_email_roundtrip_script": ROUNDTRIP_SCRIPT,
        "return_code": completed.returncode,
    }

    if completed.returncode != 0:
        raise RuntimeError(f"support email canary failed with exit code {completed.returncode}")

    return result


def handler(event: Optional[dict], context: Optional[object]) -> Dict[str, object]:
    del event, context

    _hydrate_webhook_env()
    return _run_canary()
