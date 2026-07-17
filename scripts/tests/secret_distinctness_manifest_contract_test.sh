#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_PATH="$REPO_ROOT/docs/private/secret_distinctness_manifest.md"

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

require_file "$MANIFEST_PATH"

require_pattern '^# Secret Distinctness Manifest$' "$MANIFEST_PATH"
require_pattern '^## PURPOSE$' "$MANIFEST_PATH"
require_pattern '^## Scope$' "$MANIFEST_PATH"
require_pattern '^## Distinctness Contract Table$' "$MANIFEST_PATH"
require_pattern '^## Stripe Constraint Details$' "$MANIFEST_PATH"
require_pattern '^## Consumer Contract \(Stage 2\)$' "$MANIFEST_PATH"
require_pattern '^## Not In This Stage$' "$MANIFEST_PATH"
require_pattern '^## Security Review Findings \(Stage 1\)$' "$MANIFEST_PATH"

require_literal '/fjcloud/prod/*' "$MANIFEST_PATH"
require_literal '/fjcloud/staging/*' "$MANIFEST_PATH"
require_literal '| env_var | prod_ssm_key | staging_ssm_key | constraint_type | pattern_contract | rationale |' "$MANIFEST_PATH"
require_literal 'must_differ' "$MANIFEST_PATH"
require_literal 'prod_prefix' "$MANIFEST_PATH"
require_literal 'staging_prefix' "$MANIFEST_PATH"
require_literal 'STRIPE_SECRET_KEY' "$MANIFEST_PATH"
require_literal 'STRIPE_PUBLISHABLE_KEY' "$MANIFEST_PATH"
require_literal 'STRIPE_WEBHOOK_SECRET' "$MANIFEST_PATH"
require_literal 'PRIVACY_CARD_REUSABLE_TOKEN' "$MANIFEST_PATH"
require_literal 'sk_live_' "$MANIFEST_PATH"
require_literal 'sk_test_' "$MANIFEST_PATH"
require_literal 'pk_live_' "$MANIFEST_PATH"
require_literal 'pk_test_' "$MANIFEST_PATH"
require_literal 'whsec_' "$MANIFEST_PATH"
require_literal '/fjcloud/prod/privacy_card_reusable_token' "$MANIFEST_PATH"
require_literal '/fjcloud/staging/privacy_card_reusable_token' "$MANIFEST_PATH"
require_literal '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "$MANIFEST_PATH"
require_literal 'scripts/audit_prod_secret_distinctness.sh' "$MANIFEST_PATH"

echo 'PASS: secret distinctness manifest contract validated'
