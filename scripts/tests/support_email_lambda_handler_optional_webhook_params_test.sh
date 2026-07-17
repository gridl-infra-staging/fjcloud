#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HANDLER_PATH="$REPO_ROOT/ops/terraform/support_email_canary/lambda_handler.py"

python3 - "$HANDLER_PATH" <<'PY'
import importlib.util
import pathlib
import sys
import types

handler_path = pathlib.Path(sys.argv[1])
sys.modules.setdefault("boto3", types.SimpleNamespace(client=lambda *args, **kwargs: None))
spec = importlib.util.spec_from_file_location("support_email_lambda_handler", handler_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class FakeClientError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.response = {"Error": {"Code": code, "Message": message}}


class MissingParameterClient:
    def get_parameter(self, Name, WithDecryption):  # noqa: N803
        raise FakeClientError("ParameterNotFound", f"Missing {Name}")


resolved = module._resolve_webhook_value("/fjcloud/prod/slack_webhook_url", MissingParameterClient())
if resolved != "":
    raise SystemExit(f"expected empty fallback, got {resolved!r}")


class AccessDeniedClient:
    def get_parameter(self, Name, WithDecryption):  # noqa: N803
        raise FakeClientError("AccessDeniedException", f"Denied {Name}")


resolved = module._resolve_webhook_value("/fjcloud/prod/discord_webhook_url", AccessDeniedClient())
if resolved != "":
    raise SystemExit(f"expected empty fallback on access denied, got {resolved!r}")
PY
