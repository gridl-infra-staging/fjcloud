#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/lib/vlm_env_helpers.sh"
source "${SCRIPT_DIR}/lib/vlm_judge_prompt.sh"

readonly EXIT_USAGE=64
readonly EXIT_REQUIRED_ARG=2
readonly EXIT_MISSING_INPUT=3
readonly EXIT_SCHEMA_FAILURE=4
readonly EXIT_BUDGET_REFUSAL=5
readonly EXIT_TRANSPORT_FAILURE=6

readonly ANTHROPIC_VERSION="2023-06-01"
readonly DEFAULT_API_BASE_URL="https://api.anthropic.com"
readonly TRUSTED_API_BASE_URL="https://api.anthropic.com"
readonly DEFAULT_MAX_BUDGET_USD="5.00"
readonly DEFAULT_MAX_RETRIES=3
readonly INPUT_RATE_USD_PER_MTOK=3
readonly LONG_CONTEXT_INPUT_RATE_USD_PER_MTOK=6
readonly LONG_CONTEXT_THRESHOLD_TOKENS=200000

screenshot_path=""
manifesto_path=""
postmortems_path=""
screen_spec_path=""
output_path=""
tuple_context_path=""
api_base_url="${DEFAULT_API_BASE_URL}"
max_budget_usd="${DEFAULT_MAX_BUDGET_USD}"
max_retries="${DEFAULT_MAX_RETRIES}"

cost_log_path="${REPO_ROOT}/tmp/vlm_judge/cost_log.jsonl"
tmp_output_path=""

_last_http_code=""
_last_http_body=""

usage() {
  cat <<'EOF' >&2
usage: ./scripts/vlm_judge.sh --screenshot <path> --manifesto <path> --postmortems <path> --screen-spec <path> --output <path> [--tuple-context <path>] [--max-budget-usd <amount>] [--api-base-url <url>] [--max-retries <n>]

`--api-base-url` is restricted to https://api.anthropic.com because this
script sends the resolved Anthropic API key to that origin.
EOF
}

cleanup_on_exit() {
  local status=$?

  # Remove stale output for every non-zero exit path so downstream jobs never
  # consume previous successful artifacts after a failed invocation.
  if [[ "${status}" -ne 0 ]] && [[ -n "${output_path}" ]]; then
    rm -f "${output_path}" 2>/dev/null || true
  fi

  if [[ -n "${tmp_output_path}" ]]; then
    rm -f "${tmp_output_path}" 2>/dev/null || true
  fi
}

trap cleanup_on_exit EXIT

is_non_negative_decimal() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

require_trusted_api_base_url() {
  local value="$1"

  python3 - "${value}" "${TRUSTED_API_BASE_URL}" <<'PY'
from urllib.parse import urlsplit
import sys

candidate = sys.argv[1]
trusted = sys.argv[2]

try:
    candidate_parts = urlsplit(candidate)
    trusted_parts = urlsplit(trusted)
except ValueError:
    print(
        f"Invalid --api-base-url: {candidate}. Only {trusted} is allowed.",
        file=sys.stderr,
    )
    raise SystemExit(1)

candidate_path = candidate_parts.path or ""
trusted_path = trusted_parts.path or ""

is_trusted = (
    candidate_parts.scheme == trusted_parts.scheme
    and candidate_parts.hostname == trusted_parts.hostname
    and candidate_parts.username is None
    and candidate_parts.password is None
    and candidate_parts.port in (None, 443)
    and candidate_path in ("", trusted_path, "/")
    and candidate_parts.query == ""
    and candidate_parts.fragment == ""
)

if not is_trusted:
    print(
        f"Invalid --api-base-url: {candidate}. Only {trusted} is allowed.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

resolve_primary_checkout_root() {
  local git_common_dir_raw=""
  local git_common_dir=""

  if ! git_common_dir_raw="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null)"; then
    return 1
  fi

  if ! git_common_dir="$(cd "${REPO_ROOT}" && cd "${git_common_dir_raw}" && pwd 2>/dev/null)"; then
    return 1
  fi

  (cd "${git_common_dir}/.." && pwd)
}

resolve_anthropic_api_key() {
  local resolved="${ANTHROPIC_API_KEY:-}"
  local checkout_secret_file="${REPO_ROOT}/.secret/.env.secret"
  local primary_checkout_root=""
  local primary_secret_file=""

  if [[ -n "${resolved}" ]]; then
    printf '%s\n' "${resolved}"
    return 0
  fi

  if [[ -f "${checkout_secret_file}" ]]; then
    resolved="$(read_env_value_trimmed "${checkout_secret_file}" "ANTHROPIC_API_KEY")"
    if [[ -n "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  fi

  if primary_checkout_root="$(resolve_primary_checkout_root)"; then
    primary_secret_file="${primary_checkout_root}/.secret/.env.secret"
    if [[ -f "${primary_secret_file}" ]]; then
      resolved="$(read_env_value_trimmed "${primary_secret_file}" "ANTHROPIC_API_KEY")"
      if [[ -n "${resolved}" ]]; then
        printf '%s\n' "${resolved}"
        return 0
      fi
    fi
  fi

  return 1
}

read_logged_cumulative_cost_usd() {
  if [[ ! -f "${cost_log_path}" ]]; then
    printf '0\n'
    return 0
  fi

  jq -s '[.[] | (.estimated_request_cost_usd // 0)] | add // 0' "${cost_log_path}" 2>/dev/null || printf '0\n'
}

calculate_estimated_request_cost_usd() {
  local input_tokens="$1"
  local selected_input_rate="${INPUT_RATE_USD_PER_MTOK}"

  if (( input_tokens > LONG_CONTEXT_THRESHOLD_TOKENS )); then
    selected_input_rate="${LONG_CONTEXT_INPUT_RATE_USD_PER_MTOK}"
  fi

  awk -v tokens="${input_tokens}" -v rate="${selected_input_rate}" 'BEGIN { printf "%.8f", (tokens * rate) / 1000000 }'
}

append_cost_entry() {
  local model="$1"
  local input_tokens="$2"
  local output_tokens="$3"
  local estimated_request_cost_usd="$4"
  local cumulative_estimated_cost_usd="$5"
  local status="$6"

  mkdir -p "$(dirname "${cost_log_path}")"

  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg model "${model}" \
    --arg status "${status}" \
    --arg max_budget_usd "${max_budget_usd}" \
    --argjson input_tokens "${input_tokens}" \
    --argjson output_tokens "${output_tokens}" \
    --argjson estimated_request_cost_usd "${estimated_request_cost_usd}" \
    --argjson cumulative_estimated_cost_usd "${cumulative_estimated_cost_usd}" \
    '{
      ts: $ts,
      model: $model,
      status: $status,
      input_tokens: $input_tokens,
      output_tokens: $output_tokens,
      estimated_request_cost_usd: $estimated_request_cost_usd,
      cumulative_estimated_cost_usd: $cumulative_estimated_cost_usd,
      max_budget_usd: ($max_budget_usd | tonumber)
    }' >> "${cost_log_path}"
}

post_json_request() {
  local url="$1"
  local request_payload="$2"
  local anthropic_api_key="$3"
  local response_file=""
  local payload_file=""

  # Write payload to a temp file and pass it to curl with --data-binary @file
  # because vision payloads (base64-encoded screenshot + manifesto + postmortems
  # + screen spec) routinely exceed the 1MB macOS ARG_MAX, which silently
  # causes argv-based curl --data invocations to fail with HTTP 000.
  response_file="$(mktemp)"
  payload_file="$(mktemp)"
  printf '%s' "${request_payload}" > "${payload_file}"
  _last_http_code="$(curl -sS -o "${response_file}" -w '%{http_code}' \
    --max-time 60 \
    -X POST \
    "${url}" \
    -H "x-api-key: ${anthropic_api_key}" \
    -H "anthropic-version: ${ANTHROPIC_VERSION}" \
    -H 'content-type: application/json' \
    --data-binary "@${payload_file}" 2>/dev/null)" || _last_http_code="000"
  _last_http_body="$(cat "${response_file}")"
  rm -f "${response_file}" "${payload_file}"
}

post_messages_with_retry() {
  local url="$1"
  local request_payload="$2"
  local anthropic_api_key="$3"
  local attempt=1
  local delay_seconds=1

  # Keep validate_deployment's retry loop shape: bounded attempts, sleep
  # between retries, and explicit terminal failure when retries are exhausted.
  while [[ ${attempt} -le ${max_retries} ]]; do
    post_json_request "${url}" "${request_payload}" "${anthropic_api_key}"

    if [[ "${_last_http_code}" == "200" ]]; then
      return 0
    fi

    if [[ "${_last_http_code}" != "429" ]]; then
      return 1
    fi

    if [[ ${attempt} -lt ${max_retries} ]]; then
      sleep "${delay_seconds}"
      delay_seconds=$((delay_seconds * 2))
    fi

    attempt=$((attempt + 1))
  done

  return 1
}

# /v1/messages/count_tokens rejects completion-only fields like max_tokens.
build_count_tokens_payload() {
  local request_payload="$1"
  printf '%s' "${request_payload}" | jq -c '
    with_entries(
      select(
        .key == "model"
        or .key == "messages"
        or .key == "system"
        or .key == "tools"
        or .key == "tool_choice"
      )
    )
  '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --screenshot)
      [[ $# -ge 2 ]] || { echo "Missing value for --screenshot" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      screenshot_path="$2"
      shift 2
      ;;
    --manifesto)
      [[ $# -ge 2 ]] || { echo "Missing value for --manifesto" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      manifesto_path="$2"
      shift 2
      ;;
    --postmortems)
      [[ $# -ge 2 ]] || { echo "Missing value for --postmortems" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      postmortems_path="$2"
      shift 2
      ;;
    --screen-spec)
      [[ $# -ge 2 ]] || { echo "Missing value for --screen-spec" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      screen_spec_path="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      output_path="$2"
      shift 2
      ;;
    --tuple-context)
      [[ $# -ge 2 ]] || { echo "Missing value for --tuple-context" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      tuple_context_path="$2"
      shift 2
      ;;
    --api-base-url)
      [[ $# -ge 2 ]] || { echo "Missing value for --api-base-url" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      api_base_url="$2"
      shift 2
      ;;
    --max-budget-usd)
      [[ $# -ge 2 ]] || { echo "Missing value for --max-budget-usd" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      max_budget_usd="$2"
      shift 2
      ;;
    --max-retries)
      [[ $# -ge 2 ]] || { echo "Missing value for --max-retries" >&2; exit "${EXIT_REQUIRED_ARG}"; }
      max_retries="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit "${EXIT_USAGE}"
      ;;
  esac
done

if [[ -z "${screenshot_path}" ]]; then
  echo "Missing required --screenshot" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if [[ -z "${manifesto_path}" ]]; then
  echo "Missing required --manifesto" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if [[ -z "${postmortems_path}" ]]; then
  echo "Missing required --postmortems" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if [[ -z "${screen_spec_path}" ]]; then
  echo "Missing required --screen-spec" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if [[ -z "${output_path}" ]]; then
  echo "Missing required --output" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if [[ ! "${max_retries}" =~ ^[0-9]+$ ]] || [[ "${max_retries}" -le 0 ]]; then
  echo "Invalid --max-retries: ${max_retries}" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if ! is_non_negative_decimal "${max_budget_usd}"; then
  echo "Invalid --max-budget-usd: ${max_budget_usd}" >&2
  exit "${EXIT_REQUIRED_ARG}"
fi
if ! require_trusted_api_base_url "${api_base_url}"; then
  exit "${EXIT_REQUIRED_ARG}"
fi

if [[ ! -f "${screenshot_path}" ]]; then
  echo "Missing input file: ${screenshot_path}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi
if [[ ! -f "${manifesto_path}" ]]; then
  echo "Missing input file: ${manifesto_path}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi
if [[ ! -f "${postmortems_path}" ]]; then
  echo "Missing input file: ${postmortems_path}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi
if [[ ! -f "${screen_spec_path}" ]]; then
  echo "Missing input file: ${screen_spec_path}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi
if [[ -n "${tuple_context_path}" ]] && [[ ! -f "${tuple_context_path}" ]]; then
  echo "Missing input file: ${tuple_context_path}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi

output_parent_dir="$(dirname "${output_path}")"
if [[ ! -d "${output_parent_dir}" ]]; then
  echo "Missing output parent directory: ${output_parent_dir}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi

if ! anthropic_api_key="$(resolve_anthropic_api_key)"; then
  echo "Missing Anthropic API key. Set ANTHROPIC_API_KEY or provide .secret/.env.secret in checkout/primary checkout." >&2
  exit "${EXIT_MISSING_INPUT}"
fi

if ! request_payload="$(build_vlm_judge_prompt "${screenshot_path}" "${manifesto_path}" "${postmortems_path}" "${screen_spec_path}" "${tuple_context_path}")"; then
  echo "Failed to build VLM judge prompt payload" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi

model_name="$(printf '%s' "${request_payload}" | jq -r '.model // empty' 2>/dev/null || true)"
if [[ -z "${model_name}" ]]; then
  model_name="${VLM_JUDGE_DEFAULT_MODEL}"
fi

count_tokens_url="${api_base_url%/}/v1/messages/count_tokens"
messages_url="${api_base_url%/}/v1/messages"

if ! count_tokens_payload="$(build_count_tokens_payload "${request_payload}")"; then
  echo "Failed to build token-count payload" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi

post_json_request "${count_tokens_url}" "${count_tokens_payload}" "${anthropic_api_key}"
if [[ "${_last_http_code}" != "200" ]]; then
  echo "Token-count request failed with HTTP ${_last_http_code}: ${_last_http_body}" >&2
  exit "${EXIT_TRANSPORT_FAILURE}"
fi

input_tokens="$(printf '%s' "${_last_http_body}" | jq -er '.input_tokens' 2>/dev/null || true)"
if [[ -z "${input_tokens}" ]] || [[ ! "${input_tokens}" =~ ^[0-9]+$ ]]; then
  echo "Token-count response missing input_tokens" >&2
  exit "${EXIT_TRANSPORT_FAILURE}"
fi

estimated_request_cost_usd="$(calculate_estimated_request_cost_usd "${input_tokens}")"
prior_cumulative_cost_usd="$(read_logged_cumulative_cost_usd)"
projected_cumulative_cost_usd="$(awk -v prior="${prior_cumulative_cost_usd}" -v current="${estimated_request_cost_usd}" 'BEGIN { printf "%.8f", prior + current }')"

# Enforce budget before /v1/messages so over-cap requests never hit the
# completion endpoint.
if awk -v projected="${projected_cumulative_cost_usd}" -v budget="${max_budget_usd}" 'BEGIN { exit !(projected > budget) }'; then
  append_cost_entry "${model_name}" "${input_tokens}" "0" "${estimated_request_cost_usd}" "${projected_cumulative_cost_usd}" "budget_refused"
  echo "Refusing request over budget: projected ${projected_cumulative_cost_usd} exceeds ${max_budget_usd}" >&2
  exit "${EXIT_BUDGET_REFUSAL}"
fi

if ! post_messages_with_retry "${messages_url}" "${request_payload}" "${anthropic_api_key}"; then
  append_cost_entry "${model_name}" "${input_tokens}" "0" "${estimated_request_cost_usd}" "${projected_cumulative_cost_usd}" "transport_failure"
  echo "Anthropic messages request failed with HTTP ${_last_http_code}: ${_last_http_body}" >&2
  exit "${EXIT_TRANSPORT_FAILURE}"
fi

output_tokens="$(printf '%s' "${_last_http_body}" | jq -r '.usage.output_tokens // 0' 2>/dev/null || true)"
if [[ -z "${output_tokens}" ]] || [[ ! "${output_tokens}" =~ ^[0-9]+$ ]]; then
  output_tokens="0"
fi

stop_reason="$(printf '%s' "${_last_http_body}" | jq -r '.stop_reason // empty' 2>/dev/null || true)"
if [[ "${stop_reason}" == "refusal" ]]; then
  append_cost_entry "${model_name}" "${input_tokens}" "${output_tokens}" "${estimated_request_cost_usd}" "${projected_cumulative_cost_usd}" "refusal"
  echo "Anthropic refusal" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi
if [[ "${stop_reason}" == "max_tokens" ]]; then
  append_cost_entry "${model_name}" "${input_tokens}" "${output_tokens}" "${estimated_request_cost_usd}" "${projected_cumulative_cost_usd}" "truncated"
  echo "Anthropic response truncated" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi

if ! judgment_json="$(extract_vlm_judgment_json "${_last_http_body}" 2>&1)"; then
  append_cost_entry "${model_name}" "${input_tokens}" "${output_tokens}" "${estimated_request_cost_usd}" "${projected_cumulative_cost_usd}" "schema_failure"
  echo "${judgment_json}" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi

append_cost_entry "${model_name}" "${input_tokens}" "${output_tokens}" "${estimated_request_cost_usd}" "${projected_cumulative_cost_usd}" "success"

# Inject the per-call estimated cost into the output JSON so the
# product-fit lane (run_product_fit_lane.sh:429) can roll it up into
# `tmp/product_fit_lane/<sha>/lane_summary.json`. Without this, every
# row reports `cost: 0.0` even though the cost is logged in
# `cost_log.jsonl` — the lane summary is the document operators read,
# so the gap was effectively a silent zero-truth bug.
#
# `cost` is a top-level numeric field (not nested under usage/etc.) so
# the lane runner's `float(payload.get("cost", 0.0))` reads it cleanly
# without any schema changes on its side. Locked in by
# scripts/tests/vlm_judge_test.sh::scenario_output_includes_cost_field
# which compares the value against the matching cost_log.jsonl entry.
judgment_json_with_cost="$(printf '%s' "${judgment_json}" | jq -c \
  --argjson cost "${estimated_request_cost_usd}" \
  '. + {cost: $cost}')"

# Atomic output write avoids partially written files when the process exits
# during serialization.
tmp_output_path="$(mktemp "${output_path}.tmp.XXXXXX")"
printf '%s\n' "${judgment_json_with_cost}" > "${tmp_output_path}"
mv "${tmp_output_path}" "${output_path}"
tmp_output_path=""
