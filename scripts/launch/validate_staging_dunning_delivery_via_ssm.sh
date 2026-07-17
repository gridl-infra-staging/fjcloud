#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validation_json.sh"
source "$SCRIPT_DIR/../lib/env.sh"

usage() {
    cat <<'USAGE'
Usage:
  STAGING_DUNNING_REMOTE_CHECKOUT_DIR=<remote-checkout-dir> \
  STAGING_DUNNING_REMOTE_ENV_FILE=<remote-env-file> \
  bash scripts/launch/validate_staging_dunning_delivery_via_ssm.sh \
    --env-file <local-env-file> --month <YYYY-MM> --confirm-live-mutation
USAGE
}

LOCAL_ENV_FILE=""
MONTH=""
CONFIRM=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || { echo "--env-file requires value" >&2; usage >&2; exit 2; }
            LOCAL_ENV_FILE="$2"
            shift 2
            ;;
        --month)
            [[ $# -ge 2 ]] || { echo "--month requires value" >&2; usage >&2; exit 2; }
            MONTH="$2"
            shift 2
            ;;
        --confirm-live-mutation)
            CONFIRM=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$LOCAL_ENV_FILE" && -r "$LOCAL_ENV_FILE" ]] || {
    echo "readable local --env-file is required" >&2
    exit 2
}
[[ -n "$MONTH" && "$CONFIRM" -eq 1 ]] || {
    echo "--month and --confirm-live-mutation are required" >&2
    exit 2
}

REMOTE_CHECKOUT_DIR="${STAGING_DUNNING_REMOTE_CHECKOUT_DIR:-}"
REMOTE_ENV_FILE="${STAGING_DUNNING_REMOTE_ENV_FILE:-}"
SSM_EXEC_SCRIPT="${STAGING_DUNNING_SSM_EXEC_SCRIPT:-$SCRIPT_DIR/ssm_exec_staging.sh}"
derive_staging_dunning_inbox_env_defaults
INBOUND_S3_URI="${INBOUND_ROUNDTRIP_S3_URI}"
SES_REGION_VALUE="${SES_REGION}"

[[ -n "$REMOTE_CHECKOUT_DIR" ]] || {
    echo "STAGING_DUNNING_REMOTE_CHECKOUT_DIR is required" >&2
    exit 2
}
[[ -n "$REMOTE_ENV_FILE" ]] || {
    echo "STAGING_DUNNING_REMOTE_ENV_FILE is required" >&2
    exit 2
}
[[ -x "$SSM_EXEC_SCRIPT" ]] || {
    echo "missing executable SSM exec script: $SSM_EXEC_SCRIPT" >&2
    exit 2
}

REMOTE_CMD="$(cat <<EOF
set -euo pipefail
cd ${REMOTE_CHECKOUT_DIR}
if [[ -d ${REMOTE_CHECKOUT_DIR}/bin ]]; then
  export PATH=${REMOTE_CHECKOUT_DIR}/bin:\$PATH
fi
bash scripts/validate_staging_dunning_delivery.sh --env-file ${REMOTE_ENV_FILE} --month '${MONTH}' --confirm-live-mutation
EOF
)"

if ! remote_output="$("$SSM_EXEC_SCRIPT" "$REMOTE_CMD" 2>&1)"; then
    printf '%s\n' "$remote_output"
    exit 1
fi

result="$(validation_json_get_field "$remote_output" "result")"
[[ "$result" == "passed" ]] || {
    printf '%s\n' "$remote_output"
    exit 1
}

local_artifact_dir="$(mktemp -d /tmp/fjcloud_dunning_via_ssm_XXXXXX)"
{
    printf 'region=%s\n' "$SES_REGION_VALUE"
    printf 's3_uri=%s\n' "$INBOUND_S3_URI"
} > "${local_artifact_dir}/inbound_s3_scope.txt"

python3 - "$remote_output" "$local_artifact_dir" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["artifact_dir"] = sys.argv[2]
print(json.dumps(payload))
PY
