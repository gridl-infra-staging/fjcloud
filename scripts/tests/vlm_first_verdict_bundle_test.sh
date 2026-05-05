#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/lib/test_runner.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"

new_tmp_dir() {
  mktemp -d
}

assert_file_contains() {
  local file_path="$1"
  local pattern="$2"
  local message="$3"
  if grep -E -n -- "$pattern" "$file_path" >/dev/null 2>&1; then
    pass "$message"
  else
    fail "$message"
  fi
}

test_prompt_requires_rule_id_anchor_wording() {
  local prompt_path="${REPO_ROOT}/scripts/vlm/lib/vlm_judge_prompt.sh"
  assert_file_contains "$prompt_path" 'Each entry in \\"violations\\" must include \\"rule_id\\"' "prompt requires per-violation rule_id"
  assert_file_contains "$prompt_path" 'exact M\.\*' "prompt mentions exact M.* anchors"
  assert_file_contains "$prompt_path" 'P\.\* anchor' "prompt mentions exact P.* anchors"
}

test_manifest_export_contract() {
  local manifest_json
  manifest_json="$(cd "${REPO_ROOT}/web" && node --experimental-strip-types ./tests/e2e-ui/full/vlm_capture/export_manifest.ts --repo-root "${REPO_ROOT}")"

  assert_valid_json "$manifest_json" "manifest export is valid JSON"

  if python3 - "$manifest_json" "$REPO_ROOT" <<PY
import json
import os
import sys

payload = json.loads(sys.argv[1])
repo_root = sys.argv[2]
entries = payload.get("entries", [])
if not isinstance(entries, list) or not entries:
    raise SystemExit("entries missing")

producible = [entry for entry in entries if entry.get("is_producible")]
unproducible = [entry for entry in entries if not entry.get("is_producible")]
if payload.get("producible_capture_count") != len(producible):
    raise SystemExit("producible count mismatch")
if len(unproducible) != 4:
    raise SystemExit("expected four unproducible tuples")

for entry in entries:
    spec_path = entry.get("screen_spec_path")
    if not spec_path:
        raise SystemExit("missing screen_spec_path")
    absolute = os.path.join(repo_root, spec_path)
    if not os.path.isfile(absolute):
        raise SystemExit(f"missing spec file: {spec_path}")
    if entry.get("artifact_filename") is None:
        raise SystemExit("missing artifact_filename")
PY
  then
    pass "manifest export includes resolved specs, artifact names, and expected tuple partition"
  else
    fail "manifest export contract failed"
  fi
}

write_mock_judge_binary() {
  local path="$1"
  local call_log_path="$2"
  local refusal_on_call="${3:-0}"

  cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

call_log_path="__CALL_LOG_PATH__"
refusal_on_call="__REFUSAL_ON_CALL__"
count_file="$(dirname "$call_log_path")/judge_call_count.txt"

if [[ ! -f "$count_file" ]]; then
  echo 0 > "$count_file"
fi

call_count="$(cat "$count_file")"
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$count_file"
printf '%s\n' "$*" >> "$call_log_path"

if [[ "$refusal_on_call" -gt 0 && "$call_count" -eq "$refusal_on_call" ]]; then
  exit 5
fi

output_path=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cat > "$output_path" <<JSON
{"screen":"mock","score":1,"verdict":"pass","summary":"ok","violations":[],"actions":[],"cost":0.1}
JSON
MOCK

  sed -i.bak "s|__CALL_LOG_PATH__|${call_log_path}|g; s|__REFUSAL_ON_CALL__|${refusal_on_call}|g" "$path"
  rm -f "${path}.bak"
  chmod +x "$path"
}

write_manifest_fixture() {
  local path="$1"
  local screenshot_dir="$2"
  local mode="$3"

  if [[ "$mode" == "missing-producible" ]]; then
    cat > "$path" <<JSON
{
  "producible_capture_count": 2,
  "entries": [
    {
      "lane": "auth",
      "path": "/dashboard",
      "state": "success",
      "viewport": "desktop",
      "setup": "auth_fresh_user_with_index",
      "is_producible": true,
      "artifact_filename": "auth__dashboard__success__desktop.png",
      "artifact_relpath": "web/tmp/screens/auth__dashboard__success__desktop.png",
      "screen_spec_path": "docs/screen_specs/dashboard.md"
    },
    {
      "lane": "auth",
      "path": "/dashboard",
      "state": "success",
      "viewport": "mobile_narrow",
      "setup": "auth_fresh_user_with_index",
      "is_producible": true,
      "artifact_filename": "auth__dashboard__success__mobile_narrow.png",
      "artifact_relpath": "web/tmp/screens/auth__dashboard__success__mobile_narrow.png",
      "screen_spec_path": "docs/screen_specs/dashboard.md"
    },
    {
      "lane": "admin",
      "path": "/admin/customers",
      "state": "empty",
      "viewport": "desktop",
      "setup": "unproducible_requires_server_side_mocking",
      "is_producible": false,
      "artifact_filename": "admin__admin_customers__empty__desktop.png",
      "artifact_relpath": "web/tmp/screens/admin__admin_customers__empty__desktop.png",
      "screen_spec_path": "docs/screen_specs/admin_customers.md"
    }
  ]
}
JSON
    touch "${screenshot_dir}/auth__dashboard__success__desktop.png"
    return
  fi

  cat > "$path" <<JSON
{
  "producible_capture_count": 3,
  "entries": [
    {
      "lane": "public",
      "path": "/terms",
      "state": "success",
      "viewport": "desktop",
      "setup": "public_unauth",
      "is_producible": true,
      "artifact_filename": "public__terms__success__desktop.png",
      "artifact_relpath": "web/tmp/screens/public__terms__success__desktop.png",
      "screen_spec_path": "docs/screen_specs/terms.md"
    },
    {
      "lane": "auth",
      "path": "/dashboard",
      "state": "success",
      "viewport": "desktop",
      "setup": "auth_fresh_user_with_index",
      "is_producible": true,
      "artifact_filename": "auth__dashboard__success__desktop.png",
      "artifact_relpath": "web/tmp/screens/auth__dashboard__success__desktop.png",
      "screen_spec_path": "docs/screen_specs/dashboard.md"
    },
    {
      "lane": "auth",
      "path": "/dashboard",
      "state": "empty",
      "viewport": "mobile_narrow",
      "setup": "auth_fresh_user",
      "is_producible": true,
      "artifact_filename": "auth__dashboard__empty__mobile_narrow.png",
      "artifact_relpath": "web/tmp/screens/auth__dashboard__empty__mobile_narrow.png",
      "screen_spec_path": "docs/screen_specs/dashboard.md"
    },
    {
      "lane": "admin",
      "path": "/admin/customers",
      "state": "error",
      "viewport": "desktop",
      "setup": "unproducible_requires_server_side_mocking",
      "is_producible": false,
      "artifact_filename": "admin__admin_customers__error__desktop.png",
      "artifact_relpath": "web/tmp/screens/admin__admin_customers__error__desktop.png",
      "screen_spec_path": "docs/screen_specs/admin_customers.md"
    }
  ]
}
JSON

  touch "${screenshot_dir}/public__terms__success__desktop.png"
  touch "${screenshot_dir}/auth__dashboard__success__desktop.png"
  touch "${screenshot_dir}/auth__dashboard__empty__mobile_narrow.png"
}

create_tall_png() {
  local output_path="$1"
  python3 - "$output_path" <<'PY'
import struct
import zlib
import binascii
import sys

output_path = sys.argv[1]
width = 1
height = 9001

raw_rows = []
for _ in range(height):
    raw_rows.append(b"\x00\x00")
raw = b"".join(raw_rows)
compressed = zlib.compress(raw, level=9)

def chunk(chunk_type: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + chunk_type
        + payload
        + struct.pack(">I", binascii.crc32(chunk_type + payload) & 0xFFFFFFFF)
    )

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
png += chunk(b"IDAT", compressed)
png += chunk(b"IEND", b"")

with open(output_path, "wb") as handle:
    handle.write(png)
PY
}

write_dimension_guard_judge_binary() {
  local path="$1"
  cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

screenshot_path=""
output_path=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --screenshot)
      screenshot_path="$2"
      shift 2
      ;;
    --output)
      output_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

height="$(sips -g pixelHeight "$screenshot_path" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"
width="$(sips -g pixelWidth "$screenshot_path" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
if [[ "$height" -gt 8000 || "$width" -gt 8000 ]]; then
  exit 6
fi

cat > "$output_path" <<'JSON'
{"screen":"mock","score":1,"verdict":"pass","summary":"ok","violations":[],"actions":[],"cost":0.1}
JSON
MOCK
  chmod +x "$path"
}

test_runner_stops_when_producible_artifacts_are_missing() {
  local tmp_root manifest_path screenshot_dir mock_judge call_log bundle_dir output exit_code
  tmp_root="$(new_tmp_dir)"
  manifest_path="${tmp_root}/manifest.json"
  screenshot_dir="${tmp_root}/screens"
  mkdir -p "$screenshot_dir"

  write_manifest_fixture "$manifest_path" "$screenshot_dir" "missing-producible"

  call_log="${tmp_root}/judge_calls.log"
  mock_judge="${tmp_root}/mock_vlm_judge.sh"
  write_mock_judge_binary "$mock_judge" "$call_log"

  bundle_dir="${tmp_root}/bundle"
  mkdir -p "$bundle_dir"

  set +e
  output="$(ANTHROPIC_API_KEY="test-key" \
    STAGE6_MANIFEST_PATH="$manifest_path" \
    STAGE6_SCREENSHOT_DIR="$screenshot_dir" \
    STAGE6_VLM_JUDGE_BIN="$mock_judge" \
    STAGE6_BUNDLE_DIR="$bundle_dir" \
    bash "${REPO_ROOT}/scripts/vlm/run_first_verdict_bundle.sh" 2>&1)"
  exit_code=$?
  set -e

  if [[ "$exit_code" -ne 0 ]]; then
    pass "runner exits non-zero when producible artifacts are missing"
  else
    fail "runner should fail when producible artifacts are missing"
  fi

  assert_contains "$output" "Missing producible screenshots" "runner reports missing producible screenshot corpus"

  if [[ -f "$call_log" ]] && [[ -s "$call_log" ]]; then
    fail "runner should not call judge when completeness gate fails"
  else
    pass "runner does not call judge when completeness gate fails"
  fi

  rm -rf "$tmp_root"
}

test_runner_short_circuits_on_budget_refusal() {
  local tmp_root manifest_path screenshot_dir mock_judge call_log bundle_dir output exit_code call_count stream_file
  tmp_root="$(new_tmp_dir)"
  manifest_path="${tmp_root}/manifest.json"
  screenshot_dir="${tmp_root}/screens"
  mkdir -p "$screenshot_dir"

  write_manifest_fixture "$manifest_path" "$screenshot_dir" "budget-refusal"

  call_log="${tmp_root}/judge_calls.log"
  mock_judge="${tmp_root}/mock_vlm_judge.sh"
  write_mock_judge_binary "$mock_judge" "$call_log" 2

  bundle_dir="${tmp_root}/bundle"
  mkdir -p "$bundle_dir"

  set +e
  output="$(ANTHROPIC_API_KEY="test-key" \
    STAGE6_MANIFEST_PATH="$manifest_path" \
    STAGE6_SCREENSHOT_DIR="$screenshot_dir" \
    STAGE6_VLM_JUDGE_BIN="$mock_judge" \
    STAGE6_BUNDLE_DIR="$bundle_dir" \
    STAGE6_COST_LOG_PATH="${tmp_root}/cost_log.jsonl" \
    bash "${REPO_ROOT}/scripts/vlm/run_first_verdict_bundle.sh" 2>&1)"
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    pass "runner exits successfully on budget short-circuit with partial bundle"
  else
    fail "runner should succeed on budget short-circuit"
  fi

  call_count="$(cat "${tmp_root}/judge_call_count.txt")"
  assert_eq "$call_count" "2" "runner stops immediately after budget refusal"

  stream_file="${bundle_dir}/STREAM_C_INPUT.md"
  if [[ -f "$stream_file" ]]; then
    pass "runner writes STREAM_C_INPUT bundle output"
  else
    fail "runner did not create STREAM_C_INPUT.md"
  fi

  assert_contains "$output" "Budget refusal" "runner prints explicit budget refusal status"
  assert_file_contains "$stream_file" "## Uncovered tuples" "stream output reports uncovered tuples when budget short-circuit occurs"

  rm -rf "$tmp_root"
}

test_runner_normalizes_oversized_png_before_judge_call() {
  local tmp_root manifest_path screenshot_dir guard_judge bundle_dir output exit_code judgment_path
  tmp_root="$(new_tmp_dir)"
  manifest_path="${tmp_root}/manifest.json"
  screenshot_dir="${tmp_root}/screens"
  mkdir -p "$screenshot_dir"

  cat > "$manifest_path" <<'JSON'
{
  "producible_capture_count": 1,
  "entries": [
    {
      "lane": "admin",
      "path": "/admin/customers",
      "state": "loading",
      "viewport": "desktop",
      "setup": "admin_default",
      "is_producible": true,
      "artifact_filename": "admin__admin_customers__loading__desktop.png",
      "artifact_relpath": "web/tmp/screens/admin__admin_customers__loading__desktop.png",
      "screen_spec_path": "docs/screen_specs/admin_customers.md"
    }
  ]
}
JSON

  create_tall_png "${screenshot_dir}/admin__admin_customers__loading__desktop.png"

  guard_judge="${tmp_root}/guard_vlm_judge.sh"
  write_dimension_guard_judge_binary "$guard_judge"

  bundle_dir="${tmp_root}/bundle"
  mkdir -p "$bundle_dir"

  set +e
  output="$(ANTHROPIC_API_KEY="test-key" \
    STAGE6_MANIFEST_PATH="$manifest_path" \
    STAGE6_SCREENSHOT_DIR="$screenshot_dir" \
    STAGE6_VLM_JUDGE_BIN="$guard_judge" \
    STAGE6_BUNDLE_DIR="$bundle_dir" \
    STAGE6_COST_LOG_PATH="${tmp_root}/cost_log.jsonl" \
    bash "${REPO_ROOT}/scripts/vlm/run_first_verdict_bundle.sh" 2>&1)"
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    pass "runner normalizes oversized PNGs before judge API constraints are applied"
  else
    fail "runner should normalize oversized PNGs for judge compatibility"
  fi

  judgment_path="${bundle_dir}/judgments/admin__admin_customers__loading__desktop.json"
  if [[ -f "$judgment_path" ]]; then
    pass "runner produced judgment output after oversize normalization"
  else
    fail "runner did not produce judgment output after oversize normalization"
  fi

  assert_contains "$output" "Stage 6 first-run bundle generated" "runner completes bundle generation after normalization"

  rm -rf "$tmp_root"
}

test_aggregator_rule_mapping_contract() {
  local tmp_root manifest_path judgments_dir output_path
  tmp_root="$(new_tmp_dir)"
  manifest_path="${tmp_root}/manifest.json"
  judgments_dir="${tmp_root}/judgments"
  mkdir -p "$judgments_dir"

  cat > "$manifest_path" <<JSON
{
  "producible_capture_count": 5,
  "entries": [
    {"path":"/pricing","state":"success","viewport":"desktop","artifact_filename":"public__pricing__success__desktop.png","is_producible":true,"screen_spec_path":"docs/screen_specs/terms.md"},
    {"path":"/dashboard","state":"success","viewport":"desktop","artifact_filename":"auth__dashboard__success__desktop.png","is_producible":true,"screen_spec_path":"docs/screen_specs/dashboard.md"},
    {"path":"/terms","state":"success","viewport":"desktop","artifact_filename":"public__terms__success__desktop.png","is_producible":true,"screen_spec_path":"docs/screen_specs/terms.md"},
    {"path":"/privacy","state":"success","viewport":"mobile_narrow","artifact_filename":"public__privacy__success__mobile_narrow.png","is_producible":true,"screen_spec_path":"docs/screen_specs/privacy.md"},
    {"path":"/admin/customers","state":"error","viewport":"desktop","artifact_filename":"admin__admin_customers__error__desktop.png","is_producible":true,"screen_spec_path":"docs/screen_specs/admin_customers.md"}
  ]
}
JSON

  cat > "${judgments_dir}/public__pricing__success__desktop.json" <<JSON
{"screen":"pricing","score":0.1,"verdict":"fail","summary":"bad","violations":[{"rule_id":null,"description":"uncited"}],"actions":[]}
JSON

  cat > "${judgments_dir}/auth__dashboard__success__desktop.json" <<JSON
{"screen":"dashboard","score":0.1,"verdict":"fail","summary":"postmortem","violations":[{"rule_id":"P.legal_posture_single_source","description":"legal issue"}],"actions":[]}
JSON

  cat > "${judgments_dir}/public__terms__success__desktop.json" <<JSON
{"screen":"terms","score":0.1,"verdict":"fail","summary":"manifesto","violations":[{"rule_id":"M.palette.1","description":"palette drift"}],"actions":[]}
JSON

  cat > "${judgments_dir}/public__privacy__success__mobile_narrow.json" <<JSON
{"screen":"privacy","score":0.1,"verdict":"advisory","summary":"advisory","violations":[{"rule_id":"P.legal_posture_single_source","description":"copy"}],"actions":[]}
JSON

  cat > "${judgments_dir}/admin__admin_customers__error__desktop.json" <<JSON
{"screen":"admin","score":0.1,"verdict":"pass","summary":"clean","violations":[],"actions":[]}
JSON

  output_path="${tmp_root}/STREAM_C_INPUT.md"
  if python3 "${REPO_ROOT}/scripts/vlm/aggregate_first_verdict_bundle.py" \
    --manifest-path "$manifest_path" \
    --judgments-dir "$judgments_dir" \
    --postmortems-path "${REPO_ROOT}/web/docs/ui_postmortems.md" \
    --output "$output_path" \
    --bundle-relative-path "docs/runbooks/evidence/ui-polish/test_first_run" \
    --cost-log-path "${tmp_root}/cost_log.jsonl" \
    --uncovered-json-path "${tmp_root}/uncovered.json" \
    >/dev/null 2>&1; then
    pass "aggregator command succeeds with deterministic fixtures"
  else
    fail "aggregator command failed"
  fi

  assert_file_contains "$output_path" "### BLOCKER" "aggregator output includes BLOCKER section"
  assert_file_contains "$output_path" "### EMBARRASSING" "aggregator output includes EMBARRASSING section"
  assert_file_contains "$output_path" "### HARDENING" "aggregator output includes HARDENING section"
  assert_file_contains "$output_path" "### MAINT" "aggregator output includes MAINT section"
  assert_file_contains "$output_path" "Rule 2" "aggregator records producing rule branch"
  assert_file_contains "$output_path" "Rule 3" "aggregator records manifesto rule branch"
  assert_file_contains "$output_path" "Rule 4" "aggregator records uncited-fail branch"
  assert_file_contains "$output_path" "route=/pricing" "aggregator output preserves slash-form route paths"

  rm -rf "$tmp_root"
}

test_prompt_requires_rule_id_anchor_wording
test_manifest_export_contract
test_runner_stops_when_producible_artifacts_are_missing
test_runner_short_circuits_on_budget_refusal
test_runner_normalizes_oversized_png_before_judge_call
test_aggregator_rule_mapping_contract

run_test_summary
