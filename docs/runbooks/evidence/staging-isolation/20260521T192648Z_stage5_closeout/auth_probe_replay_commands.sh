#!/usr/bin/env bash
set -euo pipefail

# Canonical cookie name sourced from web/src/lib/auth-session-contracts.ts.
# Use python3 rather than grep -P so the replay works on the repo's macOS
# baseline as well as GNU userlands.
REPO_ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
AUTH_COOKIE="$(
  python3 - "${REPO_ROOT}/web/src/lib/auth-session-contracts.ts" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"export const AUTH_COOKIE = '([^']+)'", text)
if not match:
    sys.exit(1)
print(match.group(1))
PY
)"
if [ -z "${AUTH_COOKIE}" ]; then
  echo "ERROR: could not extract AUTH_COOKIE from web/src/lib/auth-session-contracts.ts" >&2
  exit 1
fi

# Supply credentials at runtime; do not hardcode in artifacts.
# export STAGING_FIXTURE_EMAIL='...'
# export STAGING_FIXTURE_PASSWORD='...'
if [ -z "${STAGING_FIXTURE_EMAIL:-}" ] || [ -z "${STAGING_FIXTURE_PASSWORD:-}" ]; then
  echo "ERROR: set STAGING_FIXTURE_EMAIL and STAGING_FIXTURE_PASSWORD before running this replay" >&2
  exit 1
fi

LOGIN_PAYLOAD="$(
  STAGING_FIXTURE_EMAIL="$STAGING_FIXTURE_EMAIL" \
  STAGING_FIXTURE_PASSWORD="$STAGING_FIXTURE_PASSWORD" \
  python3 - <<'PY'
import json
import os

print(json.dumps({
    "email": os.environ["STAGING_FIXTURE_EMAIL"],
    "password": os.environ["STAGING_FIXTURE_PASSWORD"],
}))
PY
)"

LOGIN_RESPONSE="$(curl -sS -H 'Content-Type: application/json' -d "$LOGIN_PAYLOAD" https://api.staging.flapjack.foo/auth/login)"
TOKEN="$(
  printf '%s' "$LOGIN_RESPONSE" | python3 -c '
import json
import sys

try:
    body = json.load(sys.stdin)
except json.JSONDecodeError:
    print("")
    raise SystemExit(0)

print(body.get("token", ""))
'
)"
if [ -z "$TOKEN" ]; then
  echo "ERROR: staging auth/login did not return a token" >&2
  exit 1
fi

curl -sS -L --max-redirs 5 \
  -H "Cookie: ${AUTH_COOKIE}=${TOKEN}" \
  -w '\nstatus=%{http_code}\nfinal_url=%{url_effective}\nredirects=%{num_redirects}\n' \
  https://cloud.staging.flapjack.foo/dashboard
