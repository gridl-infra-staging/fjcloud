#!/usr/bin/env bash
# Shared Algolia migration contract helpers.
#
# Usage:
#   algolia_invalid_credentials_contract.sh [--self-test|staging|prod]
#
# Live invalid-credentials probing of the customer migration POST route is retired.
# Use scripts/algolia_migration_safety_probe.sh for the current read-only safety
# oracle.
#
# Optional env:
#   FJCLOUD_SECRET_FILE                        Defaults to repo-local .secret/.env.secret.
#   ALGOLIA_INVALID_CREDENTIALS_APP_ID         Defaults to the public Algolia demo app "latency".
#   ALGOLIA_INVALID_CREDENTIALS_API_KEY        Defaults to an intentionally invalid key.
#   ALGOLIA_INVALID_CREDENTIALS_EVIDENCE_ROOT  Overrides evidence output root for tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=../../lib/contract_secret_env.sh
source "$REPO_ROOT/scripts/lib/contract_secret_env.sh"

DEFAULT_SECRET_FILE="$REPO_ROOT/.secret/.env.secret"
DEFAULT_ALGOLIA_APP_ID="latency"
DEFAULT_INVALID_API_KEY="fjcloud-contract-intentionally-invalid-key"
EXPECTED_API_STATUS="500"
EXPECTED_API_ERROR="internal server error"
EXPECTED_API_BODY_JSON='{"error":"internal server error"}'
EXPECTED_API_BODY_KEYS='["error"]'
EXPECTED_API_FORWARDED_INVALID_CREDENTIAL_DETAIL="false"
EXPECTED_WEB_HTTP_STATUS="200"
EXPECTED_WEB_FORM_STATUS="500"
EXPECTED_WEB_ERROR="An unexpected error occurred"
EXPECTED_WEB_BODY_JSON='{"data":"[{\"error\":1},\"An unexpected error occurred\"]","status":500,"type":"failure"}'
EXPECTED_WEB_BODY_KEYS='["data","status","type"]'

usage() {
	cat >&2 <<EOF
usage: $0 [--self-test|staging|prod]
required env:
  FJCLOUD_SECRET_FILE (optional override; default: $DEFAULT_SECRET_FILE)
  ALGOLIA_INVALID_CREDENTIALS_TENANT_TOKEN
EOF
	exit 2
}

api_origin_for() {
	case "$1" in
		prod) printf '%s' "https://api.flapjack.foo" ;;
		staging) printf '%s' "https://api.staging.flapjack.foo" ;;
		*) return 1 ;;
	esac
}

web_origin_for() {
	case "$1" in
		prod) printf '%s' "https://cloud.flapjack.foo" ;;
		staging) printf '%s' "https://cloud.staging.flapjack.foo" ;;
		*) return 1 ;;
	esac
}

json_field() {
	local input="$1"
	local expr="$2"
	printf "%s" "$input" | python3 -c "import json,sys
obj=json.load(sys.stdin)
cur=obj
for part in sys.argv[1].split('.'):
    if not isinstance(cur, dict) or part not in cur:
        print('')
        raise SystemExit(0)
    cur=cur[part]
if isinstance(cur, bool):
    print('true' if cur else 'false')
elif cur is None:
    print('')
else:
    print(cur if isinstance(cur, str) else str(cur))" "$expr" 2>/dev/null || true
}

json_string_array() {
	local input="$1"
	printf "%s" "$input" | python3 -c "import json,sys
try:
    obj=json.load(sys.stdin)
except Exception:
    print('[]')
    raise SystemExit(0)
if isinstance(obj, dict):
    print(json.dumps(sorted(str(k) for k in obj.keys()), separators=(',', ':')))
else:
    print('[]')" 2>/dev/null || printf '[]'
}

json_escape() {
	local raw="$1"
	python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$raw"
}

compact_json_or_null() {
	local raw="$1"
	printf "%s" "$raw" | python3 -c "import json,sys
try:
    print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(',', ':')))
except Exception:
    print('null')" 2>/dev/null || printf 'null'
}

migrate_payload() {
	local app_id="$1"
	local api_key="$2"
	local source_index="$3"
	python3 - "$app_id" "$api_key" "$source_index" <<'PY'
import json
import sys

print(json.dumps({
    "appId": sys.argv[1],
    "apiKey": sys.argv[2],
    "sourceIndex": sys.argv[3],
}, separators=(",", ":")))
PY
}

form_payload() {
	local app_id="$1"
	local api_key="$2"
	local source_index="$3"
	python3 - "$app_id" "$api_key" "$source_index" <<'PY'
import sys
from urllib.parse import urlencode

print(urlencode({
    "appId": sys.argv[1],
    "apiKey": sys.argv[2],
    "sourceIndex": sys.argv[3],
}))
PY
}

capture_http_response() {
	local response="$1"
	HTTP_STATUS="$(printf '%s\n' "$response" | tail -n 1)"
	HTTP_BODY="$(printf '%s\n' "$response" | sed '$d')"
}

api_invalid_detail_forwarded() {
	local body="$1"
	local error
	error="$(json_field "$body" error)"
	if printf '%s' "$body" | grep -qi "Invalid Application-ID or API key"; then
		return 0
	fi
	if printf '%s' "$error" | grep -qi "Algolia returned"; then
		return 0
	fi
	return 1
}

web_failure_status() {
	local body="$1"
	json_field "$body" status
}

web_failure_error() {
	local body="$1"
	printf "%s" "$body" | python3 -c "import json,sys
try:
    obj=json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(obj, dict):
    raise SystemExit(0)
data=obj.get('data')
if isinstance(data, dict):
    value=data.get('error')
elif isinstance(data, str):
    try:
        table=json.loads(data)
    except Exception:
        raise SystemExit(0)
    if not isinstance(table, list) or not table or not isinstance(table[0], dict):
        raise SystemExit(0)
    slot=table[0].get('error')
    if isinstance(slot, int) and 0 <= slot < len(table):
        value=table[slot]
    else:
        value=slot
else:
    raise SystemExit(0)
if isinstance(value, bool):
    print('true' if value else 'false')
elif value is None:
    print('')
else:
    print(value if isinstance(value, str) else str(value))" 2>/dev/null || true
}

make_run_dir() {
	local utc evidence_root
	utc="$(date -u +%Y%m%dT%H%M%SZ)"
	evidence_root="${ALGOLIA_INVALID_CREDENTIALS_EVIDENCE_ROOT:-$REPO_ROOT/docs/runbooks/evidence/algolia-invalid-credentials}"
	RUN_DIR="$evidence_root/$utc"
	SUMMARY_PATH="$RUN_DIR/summary.json"
	mkdir -p "$RUN_DIR"
}

write_summary_json() {
	local env="$1"
	local api_url="$2"
	local web_url="$3"
	local api_status="$4"
	local api_body="$5"
	local web_http_status="$6"
	local web_body="$7"
	local overall="$8"
	local api_error api_body_json api_keys forwarded web_form_status web_error web_body_json web_keys

	api_error="$(json_field "$api_body" error)"
	api_body_json="$(compact_json_or_null "$api_body")"
	api_keys="$(json_string_array "$api_body")"
	forwarded="false"
	if api_invalid_detail_forwarded "$api_body"; then
		forwarded="true"
	fi
	web_form_status="$(web_failure_status "$web_body")"
	web_error="$(web_failure_error "$web_body")"
	web_body_json="$(compact_json_or_null "$web_body")"
	web_keys="$(json_string_array "$web_body")"

	cat > "$SUMMARY_PATH" <<EOF
{
  "env": $(json_escape "$env"),
  "api_contract": {
    "url": $(json_escape "$api_url"),
    "http_status": $(json_escape "$api_status"),
    "error": $(json_escape "$api_error"),
    "body_json": $api_body_json,
    "body_keys": $api_keys,
    "forwarded_invalid_credential_detail": $forwarded
  },
  "web_route_baseline": {
    "url": $(json_escape "$web_url"),
    "http_status": $(json_escape "$web_http_status"),
    "form_status": $(json_escape "$web_form_status"),
    "error": $(json_escape "$web_error"),
    "body_json": $web_body_json,
    "body_keys": $web_keys
  },
  "expected": {
    "api_status": $(json_escape "$EXPECTED_API_STATUS"),
    "api_error": $(json_escape "$EXPECTED_API_ERROR"),
    "api_body_json": $EXPECTED_API_BODY_JSON,
    "api_body_keys": $EXPECTED_API_BODY_KEYS,
    "api_forwarded_invalid_credential_detail": $EXPECTED_API_FORWARDED_INVALID_CREDENTIAL_DETAIL,
    "web_http_status": $(json_escape "$EXPECTED_WEB_HTTP_STATUS"),
    "web_form_status": $(json_escape "$EXPECTED_WEB_FORM_STATUS"),
    "web_error": $(json_escape "$EXPECTED_WEB_ERROR"),
    "web_body_json": $EXPECTED_WEB_BODY_JSON,
    "web_body_keys": $EXPECTED_WEB_BODY_KEYS
  },
  "overall_verdict": $(json_escape "$overall")
}
EOF
}

run_self_test() {
	local payload encoded api_body web_body
	payload="$(migrate_payload latency invalid-key instant_search)"
	if [ "$(json_field "$payload" appId)" != "latency" ]; then
		echo "self-test FAIL: migrate payload should expose appId"
		return 1
	fi
	if [ "$(json_field "$payload" sourceIndex)" != "instant_search" ]; then
		echo "self-test FAIL: migrate payload should expose sourceIndex"
		return 1
	fi
	encoded="$(form_payload latency invalid-key instant_search)"
	if [[ "$encoded" != *"sourceIndex=instant_search"* ]]; then
		echo "self-test FAIL: form payload should include sourceIndex"
		return 1
	fi
	api_body='{"error":"internal server error"}'
	if [ "$(json_field "$api_body" error)" != "internal server error" ]; then
		echo "self-test FAIL: JSON field extraction should read error"
		return 1
	fi
	if [ "$(compact_json_or_null "$api_body")" != "$EXPECTED_API_BODY_JSON" ]; then
		echo "self-test FAIL: API body JSON baseline should be compacted"
		return 1
	fi
	if api_invalid_detail_forwarded "$api_body"; then
		echo "self-test FAIL: collapsed API baseline should not look forwarded"
		return 1
	fi
	web_body='{"type":"failure","status":500,"data":"[{\"error\":1},\"An unexpected error occurred\"]"}'
	if [ "$(web_failure_status "$web_body")" != "500" ]; then
		echo "self-test FAIL: web failure status should be extracted"
		return 1
	fi
	if [ "$(web_failure_error "$web_body")" != "An unexpected error occurred" ]; then
		echo "self-test FAIL: web failure error should be extracted"
		return 1
	fi
	if [ "$(compact_json_or_null "$web_body")" != "$EXPECTED_WEB_BODY_JSON" ]; then
		echo "self-test FAIL: web body JSON baseline should be compacted"
		return 1
	fi
	echo "self-test PASS: algolia invalid-credentials contract helpers"
}

probe_env() {
	local env="$1"
	echo "ERROR: live Algolia invalid-credentials migration contract is retired for $env; use scripts/algolia_migration_safety_probe.sh" >&2
	return 2
}

main() {
	local arg="${1:-staging}"
	case "$arg" in
		--self-test)
			run_self_test
			exit $?
			;;
		staging|prod) ;;
		*) usage ;;
	esac

	probe_env "$arg"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
