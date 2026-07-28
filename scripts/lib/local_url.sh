#!/usr/bin/env bash
# Shared local URL validation helpers for shell proof lanes.

loopback_http_url_is_valid() {
    local raw_url="$1"

    python3 - "$raw_url" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    host = parsed.hostname
    is_loopback = host == "localhost" or (
        host is not None and ipaddress.ip_address(host).is_loopback
    )
except ValueError:
    raise SystemExit(1)

if (
    parsed.scheme != "http"
    or not is_loopback
    or parsed.username is not None
    or parsed.password is not None
):
    raise SystemExit(1)
PY
}
