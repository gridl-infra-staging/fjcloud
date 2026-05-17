#!/usr/bin/env python3
"""Normalize capture artifacts into a consistent JSON structure."""

import json
import sys

REDACTED = "[REDACTED]"


def redact_json(obj, sensitive_keys):
    if isinstance(obj, dict):
        redacted = {}
        for key, value in obj.items():
            if key in sensitive_keys:
                redacted[key] = REDACTED
            else:
                redacted[key] = redact_json(value, sensitive_keys)
        return redacted
    if isinstance(obj, list):
        return [redact_json(item, sensitive_keys) for item in obj]
    return obj


capture_mode, http_code, status_value, error_message, body_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:
    body = json.loads(body_raw) if body_raw else None
except Exception:
    body = body_raw
if capture_mode == "privacy" and isinstance(body, (dict, list)):
    body = redact_json(body, {"token", "pan", "cvv"})
elif capture_mode == "step" and isinstance(body, (dict, list)):
    body = redact_json(body, {"client_secret"})
elif capture_mode == "attach" and isinstance(body, (dict, list)):
    body = redact_json(body, {"pm_id"})
try:
    http_code_value = int(http_code) if http_code != "" else None
except Exception:
    http_code_value = http_code
capture = {"http_code": http_code_value, "body": body}
if capture_mode in {"step", "attach"}:
    try:
        status_value = int(status_value) if status_value != "" else None
    except Exception:
        pass
    capture["exit_status"] = status_value
elif capture_mode == "privacy":
    capture["exit_class"] = status_value or None
    capture["error_message"] = error_message or None
print(json.dumps(capture, separators=(",", ":")))
