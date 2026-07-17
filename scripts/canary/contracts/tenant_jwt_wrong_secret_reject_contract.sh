#!/usr/bin/env bash
# Live prod fail-closed contract: tenant route rejects JWT signed with wrong secret (HTTP 401).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/live_prod_reject_probe_lib.sh"

token="$({ python3 - <<"PY"
import base64
import hashlib
import hmac
import json
import time
import uuid


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

now = int(time.time())
header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
payload = b64url(
    json.dumps(
        {
            "sub": str(uuid.uuid4()),
            "exp": now + 600,
            "iat": now,
        },
        separators=(",", ":"),
    ).encode("utf-8")
)
signing_input = f"{header}.{payload}".encode("ascii")
signature = b64url(hmac.new(b"wrong-secret", signing_input, hashlib.sha256).digest())
print(f"{header}.{payload}.{signature}")
PY
} )"

response_path="$(live_prod_response_path "tenant_jwt_wrong_secret_reject")"

capture_live_prod_response "$response_path" \
  "https://api.flapjack.foo/account" \
  -H "authorization: Bearer ${token}"

assert_status_code 401 "$response_path"
