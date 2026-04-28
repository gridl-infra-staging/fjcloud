#!/usr/bin/env bash
# set_status.sh — publish runtime service_status.json for /status hydration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

usage() {
    cat >&2 <<'USAGE'
Usage: bash scripts/set_status.sh <env> <status> [message]
  <env>    staging | prod
  <status> operational | degraded | outage
USAGE
}

die() {
    echo "ERROR: $*" >&2
    usage
    exit 1
}

is_supported_env() {
    local env_name="$1"
    [ "$env_name" = "staging" ] || [ "$env_name" = "prod" ]
}

is_supported_status() {
    local status_value="$1"
    [ "$status_value" = "operational" ] || [ "$status_value" = "degraded" ] || [ "$status_value" = "outage" ]
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    die "expected 2 or 3 arguments"
fi

target_env="$1"
status_value="$2"
message_value="${3-}"

if ! is_supported_env "$target_env"; then
    die "unsupported environment '$target_env'; supported values: staging, prod"
fi

if ! is_supported_status "$status_value"; then
    die "unsupported status '$status_value'; supported values: operational, degraded, outage"
fi

default_secret_file="$REPO_ROOT/.secret/.env.secret"
secret_file="${FJCLOUD_SECRET_FILE:-$default_secret_file}"
load_env_file "$secret_file"

bucket="fjcloud-releases-${target_env}"
object_key="service_status.json"
object_uri="s3://${bucket}/${object_key}"
public_object_url="https://${bucket}.s3.amazonaws.com/${object_key}"
published_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT

python3 - "$status_value" "$published_timestamp" "$message_value" "$#" > "$payload_file" <<'PY'
import json
import sys

status = sys.argv[1]
last_updated = sys.argv[2]
message = sys.argv[3]
arg_count = int(sys.argv[4])

payload = {
    "status": status,
    "lastUpdated": last_updated,
}

if arg_count == 3:
    payload["message"] = message

print(json.dumps(payload, separators=(",", ":")))
PY

echo "Uploading runtime status payload to ${object_uri}"
aws s3 cp "$payload_file" "$object_uri" \
    --content-type application/json \
    --cache-control no-store

echo "Verifying public object at ${public_object_url}"
public_payload="$(curl -fsS "$public_object_url")" || {
    echo "ERROR: failed to fetch ${public_object_url}" >&2
    exit 1
}

python3 - "$public_payload" <<'PY'
import json
import re
import sys

payload = json.loads(sys.argv[1])

if not isinstance(payload, dict):
    raise SystemExit("verification failed: runtime payload is not a JSON object")

extra_keys = set(payload.keys()) - {"status", "lastUpdated", "message"}
if extra_keys:
    raise SystemExit(f"verification failed: unexpected runtime keys: {sorted(extra_keys)}")

if payload.get("status") not in {"operational", "degraded", "outage"}:
    raise SystemExit("verification failed: invalid status value")

last_updated = payload.get("lastUpdated")
if not isinstance(last_updated, str):
    raise SystemExit("verification failed: lastUpdated must be a string")

iso_regex = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$")
if not iso_regex.match(last_updated):
    raise SystemExit("verification failed: lastUpdated must be UTC ISO-8601")

if "message" in payload and not isinstance(payload["message"], str):
    raise SystemExit("verification failed: message must be a string when present")
PY

echo "Published ${object_uri} and verified ${public_object_url}"
