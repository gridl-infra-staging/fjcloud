#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC_PATH="$REPO_ROOT/docs/private/secrets_inventory.md"

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

require_file "$DOC_PATH"

require_pattern "^## Scope$" "$DOC_PATH"
require_pattern "^## Inventory Table$" "$DOC_PATH"
require_pattern "^## Discovery Method$" "$DOC_PATH"

require_literal "docs/design/secret_sources.md" "$DOC_PATH"
require_literal "docs/env-vars.md" "$DOC_PATH"
require_literal "scripts/lib/env.sh" "$DOC_PATH"
require_literal "scripts/bootstrap-env-local.sh" "$DOC_PATH"
require_literal "ops/scripts/lib/generate_ssm_env.sh" "$DOC_PATH"
require_literal "ops/scripts/rds_restore_evidence.sh" "$DOC_PATH"

echo "PASS: secrets inventory document structure and owner boundaries validated"
