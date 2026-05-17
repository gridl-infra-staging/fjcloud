#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBBIE_TOML="$REPO_ROOT/.debbie.toml"

if [[ ! -f "$DEBBIE_TOML" ]]; then
  echo "ERROR: required file missing: $DEBBIE_TOML"
  exit 1
fi

if rg -q '^\s*"docs/private/secret_distinctness_manifest\.md"' "$DEBBIE_TOML"; then
  echo 'ERROR: manifest path is explicitly whitelisted in .debbie.toml'
  exit 1
fi

if rg -q '^\s*path\s*=\s*"docs/private/"' "$DEBBIE_TOML"; then
  echo 'ERROR: docs/private directory is whitelisted in .debbie.toml'
  exit 1
fi

if rg -q '^\s*"docs/private/' "$DEBBIE_TOML"; then
  echo 'ERROR: docs/private entries must not appear in sync.files whitelist'
  exit 1
fi

echo 'PASS: debbie sync scope excludes docs/private secret distinctness manifest'
