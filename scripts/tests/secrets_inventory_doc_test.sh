#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC_PATH="$REPO_ROOT/docs/private/secrets_inventory.md"
LANE7_POINTER_PATH="$REPO_ROOT/.lane7_evidence_dir"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: required file missing: $path"
    exit 1
  fi
}

require_pattern() {
  local pattern="$1"
  local path="$2"
  if ! rg -q "$pattern" "$path"; then
    echo "ERROR: expected pattern '$pattern' in $path"
    exit 1
  fi
}

require_literal() {
  local literal="$1"
  local path="$2"
  if ! rg -F -q "$literal" "$path"; then
    echo "ERROR: expected literal '$literal' in $path"
    exit 1
  fi
}

require_path_exists() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "ERROR: required evidence artifact missing: $path"
    exit 1
  fi
}

read_lane7_evidence_root() {
  if [[ ! -f "$LANE7_POINTER_PATH" ]]; then
    echo "ERROR: required pointer file missing: $LANE7_POINTER_PATH"
    exit 1
  fi

  local pointer_value
  pointer_value="$(tr -d '\r' < "$LANE7_POINTER_PATH")"
  pointer_value="${pointer_value%/}"
  if [[ -z "$pointer_value" ]]; then
    echo "ERROR: lane 7 evidence pointer is empty"
    exit 1
  fi

  echo "$pointer_value"
}

require_file "$DOC_PATH"

LANE7_EVIDENCE_ROOT="$(read_lane7_evidence_root)"

require_pattern "^## Scope$" "$DOC_PATH"
require_pattern "^## Inventory Table$" "$DOC_PATH"
require_pattern "^## Discovery Method$" "$DOC_PATH"

require_literal "docs/design/secret_sources.md" "$DOC_PATH"
require_literal "docs/env-vars.md" "$DOC_PATH"
require_literal "scripts/lib/env.sh" "$DOC_PATH"
require_literal "scripts/bootstrap-env-local.sh" "$DOC_PATH"
require_literal "ops/scripts/lib/generate_ssm_env.sh" "$DOC_PATH"
require_literal "ops/scripts/rds_restore_evidence.sh" "$DOC_PATH"
require_literal "${LANE7_EVIDENCE_ROOT}/" "$DOC_PATH"
require_literal "discovery_summary.json" "$DOC_PATH"
require_literal "iam_plan.json" "$DOC_PATH"
require_literal "stage3/simulations/summary.json" "$DOC_PATH"
require_literal "stage3/live_path_deploy_staging_success_62fabe596675b28023c8d374125cd4c758110f36_ssm_get_command_invocation.json" "$DOC_PATH"
require_path_exists "$REPO_ROOT/$LANE7_EVIDENCE_ROOT"
require_path_exists "$REPO_ROOT/$LANE7_EVIDENCE_ROOT/discovery_summary.json"
require_path_exists "$REPO_ROOT/$LANE7_EVIDENCE_ROOT/iam_plan.json"
require_path_exists "$REPO_ROOT/$LANE7_EVIDENCE_ROOT/stage3/simulations/summary.json"
require_path_exists "$REPO_ROOT/$LANE7_EVIDENCE_ROOT/stage3/live_path_deploy_staging_success_62fabe596675b28023c8d374125cd4c758110f36_ssm_get_command_invocation.json"

echo "PASS: secrets inventory document structure and owner boundaries validated"
