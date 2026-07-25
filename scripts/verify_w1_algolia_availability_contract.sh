#!/usr/bin/env bash
set -euo pipefail

treeish="${1:-HEAD}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

fail() {
  printf 'W1 Algolia availability contract missing: %s\n' "$*" >&2
  exit 1
}

cd "$repo_root"
tree="$(git rev-parse --verify "$treeish^{tree}" 2>/dev/null)" \
  || fail "tree-ish '$treeish' does not resolve to a tree"

show_file() {
  local path="$1"
  git show "$tree:$path" 2>/dev/null || fail "file '$path'"
}

require_landmark() {
  local path="$1"
  local pattern="$2"
  local content
  content="$(show_file "$path")"
  grep -Fq "$pattern" <<<"$content" \
    || fail "landmark '$pattern' in '$path'"
}

require_interface_field() {
  local path="$1"
  local interface_name="$2"
  local field_regex="$3"
  local content

  content="$(show_file "$path")"
  awk -v interface_name="$interface_name" -v field_regex="$field_regex" '
    $0 ~ "export interface " interface_name "[[:space:]]*\\{" {
      in_block = 1
      next
    }
    in_block && $0 ~ field_regex {
      found = 1
    }
    in_block && $0 ~ /^}/ {
      saw_end = 1
      exit
    }
    END {
      if (!in_block || !saw_end || !found) {
        exit 1
      }
    }
  ' <<<"$content" || fail "field '$field_regex' in interface '$interface_name' in '$path'"
}

migration_rs="infra/api/src/routes/migration.rs"
capabilities_rs="infra/api/src/routes/migration/capabilities.rs"
types_ts="web/src/lib/api/types_algolia_migration.ts"
migrate_page="web/src/routes/console/migrate/+page.svelte"
discovery_test="infra/api/tests/integration/migration_routes_test/discovery.rs"

require_landmark "$migration_rs" "fn compute_availability"
require_landmark "$migration_rs" "current_migration_availability"
require_landmark "$migration_rs" "State(state): State<AppState>"
require_landmark "$migration_rs" "reason: Option<AlgoliaMigrationAvailabilityReason>"
require_landmark "$migration_rs" "skip_serializing_if = \"Option::is_none\""
require_landmark "$capabilities_rs" "fn route_mounted_migration_capabilities"
require_landmark "$capabilities_rs" "fn engine_supported_migration_capabilities"

require_interface_field "$types_ts" "AlgoliaMigrationAvailabilityResponse" "reason[?]:"
require_interface_field "$types_ts" "AlgoliaMigrationAvailabilityWire" "reason[?]:"
require_landmark "$migrate_page" "data-testid=\"migration-available\""

require_landmark "$discovery_test" "algolia_availability_flips_available_when_flag_enabled_and_engine_supports"
require_landmark "$discovery_test" "algolia_availability_returns_typed_unavailable_payload"

printf 'W1 Algolia availability contract present in %s\n' "$treeish"
