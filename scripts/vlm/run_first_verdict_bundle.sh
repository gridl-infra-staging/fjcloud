#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/lib/vlm_env_helpers.sh"

readonly EXIT_MISSING_INPUT=3
readonly EXIT_SCHEMA_FAILURE=4
readonly EXIT_BUDGET_REFUSAL=5

timestamp_utc="$(date -u +%Y%m%dT%H%M%SZ)"

bundle_dir="${STAGE6_BUNDLE_DIR:-${REPO_ROOT}/docs/runbooks/evidence/ui-polish/${timestamp_utc}_first_run}"
manifest_path_override="${STAGE6_MANIFEST_PATH:-}"
screenshot_dir="${STAGE6_SCREENSHOT_DIR:-${REPO_ROOT}/web/tmp/screens}"
judge_bin="${STAGE6_VLM_JUDGE_BIN:-${REPO_ROOT}/scripts/vlm/vlm_judge.sh}"
manifesto_path="${STAGE6_MANIFESTO_PATH:-${REPO_ROOT}/web/docs/product_manifesto.md}"
postmortems_path="${STAGE6_POSTMORTEMS_PATH:-${REPO_ROOT}/web/docs/ui_postmortems.md}"
max_budget_usd="${STAGE6_MAX_BUDGET_USD:-5.00}"
cost_log_path="${STAGE6_COST_LOG_PATH:-${REPO_ROOT}/tmp/vlm_judge/cost_log.jsonl}"

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

preflight_anthropic_key() {
  if resolve_anthropic_api_key >/dev/null; then
    return 0
  fi
  cat >&2 <<'EOF'
Missing Anthropic API key for Stage 6 first-run bundle.
Set the key once before running this bundle command:
  export ANTHROPIC_API_KEY='<your-key>'
Reference: docs/env-vars.md (VLM Judge / ANTHROPIC_API_KEY)
EOF
  return 1
}

read_png_dimensions() {
  local image_path="$1"
  python3 - "${image_path}" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    header = handle.read(24)
if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    raise SystemExit(1)
width, height = struct.unpack(">II", header[16:24])
print(f"{width} {height}")
PY
}

normalize_screenshot_for_model() {
  local screenshot_path="$1"
  local artifact_filename="$2"
  local dimensions=""
  local width=""
  local height=""
  local normalized_path=""

  dimensions="$(read_png_dimensions "${screenshot_path}" 2>/dev/null || true)"
  if [[ -z "${dimensions}" ]]; then
    printf '%s\n' "${screenshot_path}"
    return 0
  fi

  width="${dimensions%% *}"
  height="${dimensions##* }"

  if [[ "${width}" -le 8000 && "${height}" -le 8000 ]]; then
    printf '%s\n' "${screenshot_path}"
    return 0
  fi

  if ! command -v sips >/dev/null 2>&1; then
    echo "Screenshot ${artifact_filename} exceeds 8000px and no resizer is available (missing sips)." >&2
    return 1
  fi

  mkdir -p "${bundle_dir}/normalized_screens"
  normalized_path="${bundle_dir}/normalized_screens/${artifact_filename}"
  sips -Z 8000 "${screenshot_path}" --out "${normalized_path}" >/dev/null
  printf '%s\n' "${normalized_path}"
}

bundle_relative_path() {
  local absolute_bundle="$1"
  local prefix="${REPO_ROOT}/"
  if [[ "${absolute_bundle}" == "${prefix}"* ]]; then
    printf '%s\n' "${absolute_bundle#${prefix}}"
    return
  fi
  printf '%s\n' "${absolute_bundle}"
}

if ! preflight_anthropic_key; then
  exit "${EXIT_MISSING_INPUT}"
fi

mkdir -p "${bundle_dir}/judgments"

bundle_manifest_path="${bundle_dir}/tuple_manifest.json"

if [[ -n "${manifest_path_override}" ]]; then
  cp "${manifest_path_override}" "${bundle_manifest_path}"
else
  (
    cd "${REPO_ROOT}/web"
    node --experimental-strip-types ./tests/e2e-ui/full/vlm_capture/export_manifest.ts --repo-root "${REPO_ROOT}"
  ) > "${bundle_manifest_path}"
fi

if [[ ! -f "${bundle_manifest_path}" ]]; then
  echo "Failed to materialize tuple manifest at ${bundle_manifest_path}" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi

if [[ ! -d "${screenshot_dir}" ]]; then
  echo "Missing screenshot directory: ${screenshot_dir}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi

missing_report_path="${bundle_dir}/missing_producible.json"
python3 - "${bundle_manifest_path}" "${screenshot_dir}" "${missing_report_path}" <<'PY'
import json
import os
import sys

manifest_path, screenshot_dir, output_path = sys.argv[1:4]
manifest = json.load(open(manifest_path, "r", encoding="utf-8"))
entries = manifest.get("entries", [])

producible = [entry for entry in entries if entry.get("is_producible")]
missing = []
for entry in producible:
    artifact_name = entry.get("artifact_filename", "")
    if not artifact_name:
        missing.append(entry)
        continue
    if not os.path.isfile(os.path.join(screenshot_dir, artifact_name)):
        missing.append(entry)

if manifest.get("producible_capture_count") != len(producible):
    raise SystemExit("Manifest producible_capture_count mismatch")

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(missing, handle)
PY

if [[ "$(jq 'length' "${missing_report_path}")" -gt 0 ]]; then
  echo "Missing producible screenshots; Stage 6 corpus is incomplete." >&2
  jq -r '.[] | "- \(.path) \(.state) @ \(.viewport) :: \(.artifact_filename)"' "${missing_report_path}" >&2
  exit "${EXIT_MISSING_INPUT}"
fi

mkdir -p "$(dirname "${cost_log_path}")"
if [[ -f "${cost_log_path}" ]]; then
  mv "${cost_log_path}" "${bundle_dir}/cost_log_previous_${timestamp_utc}.jsonl"
fi
: > "${cost_log_path}"

budget_refusal_index="-1"
current_index=0

while IFS=$'\t' read -r artifact_filename screen_spec_path; do
  entry_json="$(
    jq -c --arg artifact "${artifact_filename}" '
      .entries[]
      | select(.is_producible == true)
      | select(.artifact_filename == $artifact)
    ' "${bundle_manifest_path}"
  )"
  screenshot_path="${screenshot_dir}/${artifact_filename}"
  judge_screenshot_path="$(normalize_screenshot_for_model "${screenshot_path}" "${artifact_filename}")"
  output_json_path="${bundle_dir}/judgments/${artifact_filename%.png}.json"
  tuple_context_path="${bundle_dir}/tuple_context_${artifact_filename%.png}.json"
  printf '%s\n' "${entry_json}" > "${tuple_context_path}"

  set +e
  bash "${judge_bin}" \
    --screenshot "${judge_screenshot_path}" \
    --manifesto "${manifesto_path}" \
    --postmortems "${postmortems_path}" \
    --screen-spec "${REPO_ROOT}/${screen_spec_path}" \
    --output "${output_json_path}" \
    --tuple-context "${tuple_context_path}" \
    --max-budget-usd "${max_budget_usd}"
  judge_status=$?
  set -e

  rm -f "${tuple_context_path}"

  if [[ "${judge_status}" -eq "${EXIT_BUDGET_REFUSAL}" ]]; then
    budget_refusal_index="${current_index}"
    echo "Budget refusal encountered; stopping batch at tuple index ${current_index}." >&2
    break
  fi
  if [[ "${judge_status}" -ne 0 ]]; then
    echo "VLM judge failed for ${artifact_filename} with exit ${judge_status}" >&2
    exit "${judge_status}"
  fi

  current_index=$((current_index + 1))
done < <(
  jq -r '
    .entries[]
    | select(.is_producible == true)
    | [.artifact_filename, .screen_spec_path]
    | @tsv
  ' "${bundle_manifest_path}"
)

cp "${cost_log_path}" "${bundle_dir}/cost_log.jsonl"

uncovered_tuples_path="${bundle_dir}/uncovered_tuples.json"
python3 - "${bundle_manifest_path}" "${bundle_dir}/judgments" "${budget_refusal_index}" "${uncovered_tuples_path}" <<'PY'
import json
import os
import sys
from pathlib import Path

manifest_path, judgments_dir, budget_refusal_index, output_path = sys.argv[1:5]
manifest = json.load(open(manifest_path, "r", encoding="utf-8"))
judgments_directory = Path(judgments_dir)
budget_index = int(budget_refusal_index)

entries = list(manifest.get("entries", []))
producible_entries = [entry for entry in entries if entry.get("is_producible")]
uncovered = []

for entry in entries:
    if entry.get("is_producible"):
        continue
    uncovered.append(
        {
            "path": entry.get("path"),
            "state": entry.get("state"),
            "viewport": entry.get("viewport"),
            "artifact_filename": entry.get("artifact_filename"),
            "reason": entry.get("uncovered_reason")
            or "unproducible_requires_server_side_mocking",
        }
    )

if budget_index >= 0:
    for entry in producible_entries[budget_index:]:
        uncovered.append(
            {
                "path": entry.get("path"),
                "state": entry.get("state"),
                "viewport": entry.get("viewport"),
                "artifact_filename": entry.get("artifact_filename"),
                "reason": "budget_refusal",
            }
        )

for entry in producible_entries:
    judgment_name = str(entry.get("artifact_filename", "")).replace(".png", ".json")
    if not judgment_name:
        continue
    judgment_path = judgments_directory / judgment_name
    if judgment_path.exists():
        continue
    if any(item.get("artifact_filename") == entry.get("artifact_filename") for item in uncovered):
        continue
    uncovered.append(
        {
            "path": entry.get("path"),
            "state": entry.get("state"),
            "viewport": entry.get("viewport"),
            "artifact_filename": entry.get("artifact_filename"),
            "reason": "missing_judgment_output",
        }
    )

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(uncovered, handle)
PY

bundle_relative="$(bundle_relative_path "${bundle_dir}")"

python3 "${SCRIPT_DIR}/aggregate_first_verdict_bundle.py" \
  --manifest-path "${bundle_manifest_path}" \
  --judgments-dir "${bundle_dir}/judgments" \
  --postmortems-path "${postmortems_path}" \
  --output "${bundle_dir}/STREAM_C_INPUT.md" \
  --bundle-relative-path "${bundle_relative}" \
  --cost-log-path "${bundle_dir}/cost_log.jsonl" \
  --uncovered-json-path "${uncovered_tuples_path}" \
  --max-cost-usd "${max_budget_usd}"

judged_json_count="$(
  ls "${bundle_dir}/judgments"/*.json 2>/dev/null | wc -l | tr -d '[:space:]'
)"
expected_judged_count="$(
  python3 - "${bundle_manifest_path}" "${uncovered_tuples_path}" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], "r", encoding="utf-8"))
uncovered = json.load(open(sys.argv[2], "r", encoding="utf-8"))
uncovered_artifacts = {
    item.get("artifact_filename")
    for item in uncovered
    if item.get("reason") == "budget_refusal"
}
producible = [entry for entry in manifest.get("entries", []) if entry.get("is_producible")]
print(len(producible) - len(uncovered_artifacts))
PY
)"

if [[ "${judged_json_count}" != "${expected_judged_count}" ]]; then
  echo "Judgment JSON count mismatch: got ${judged_json_count}, expected ${expected_judged_count}" >&2
  exit "${EXIT_SCHEMA_FAILURE}"
fi

stream_input_path="${bundle_dir}/STREAM_C_INPUT.md"
for heading in "### BLOCKER" "### EMBARRASSING" "### HARDENING" "### MAINT" "## All-clear lanes" "## Cost ledger"; do
  if ! grep -q "^${heading}$" "${stream_input_path}"; then
    echo "Missing required STREAM_C_INPUT heading: ${heading}" >&2
    exit "${EXIT_SCHEMA_FAILURE}"
  fi
done

if [[ "$(jq 'length' "${uncovered_tuples_path}")" -gt 0 ]]; then
  if ! grep -q '^## Uncovered tuples$' "${stream_input_path}"; then
    echo "Expected uncovered-tuples section was not found" >&2
    exit "${EXIT_SCHEMA_FAILURE}"
  fi
fi

python3 - "${stream_input_path}" "${bundle_dir}/judgments" <<'PY'
import json
import re
import sys
from pathlib import Path

stream_path = Path(sys.argv[1])
judgments_dir = Path(sys.argv[2])
text = stream_path.read_text(encoding="utf-8")
judgment_files = sorted(judgments_dir.glob("*.json"))

violations_total = 0
null_rule_ids = 0
for file_path in judgment_files:
    payload = json.load(open(file_path, "r", encoding="utf-8"))
    violations = payload.get("violations", [])
    if not isinstance(violations, list):
        continue
    for violation in violations:
        if not isinstance(violation, dict):
            continue
        violations_total += 1
        if violation.get("rule_id") in (None, ""):
            null_rule_ids += 1

if violations_total:
    ratio = null_rule_ids / violations_total
    if ratio > 0.30 and "WARNING: null-rule-id ratio" not in text:
        raise SystemExit(1)
PY

echo "Stage 6 first-run bundle generated at ${bundle_dir}"
