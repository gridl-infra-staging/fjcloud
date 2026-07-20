#!/usr/bin/env bash
# Enforce hard file-size limits for source files.
#
# Limits are calibrated to flag genuinely-too-large source files while
# accommodating the line-count overhead that `prettier --write` adds when
# breaking long lines into multi-line form. Pre-prettier baseline limits
# of 800 (rs/ts) and 600 (svelte) were tripping on three borderline
# files purely because of cosmetic prettier expansion (no logical-size
# change), so the hard limits below add ~50 lines of headroom.
#
# The cognitive-complexity warnings in CLAUDE.md ("File size: 500 lines
# warning, 800 lines hard limit") remain the design-time guideline; the
# CI-enforced gate here is intentionally a hair more lenient so prettier
# reformatting alone never blocks a deploy. Substantive refactor opportunities
# above 500 lines are still in scope for code review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_DIR="${1:-$REPO_ROOT}"
BASE_DIR="$(cd "$BASE_DIR" && pwd)"

SCAN_DIRS=(
    "infra/api/src"
    "infra/metering-agent/src"
    "infra/billing/src"
    "web/src"
)

violation_count=0

# Per-file overrides for files that are intentionally allowed to exceed
# the default limit, paired with a documented reason. New entries should
# be rare and ALWAYS land with a TODO/FIXME pointing to the refactor
# that will bring the file back under the default. The override is the
# release-engineering pressure-valve, not the long-term answer.
#
# Format: relative-path-from-repo-root|limit|brief-reason
PER_FILE_OVERRIDES=(
    # 2026-07-16: merge target plan/jul14-algolia-amendments already carries
    # this migration facade at 867 lines. Keep the cap narrow so the current
    # batman merge can validate without refactoring unrelated migration owners
    # inside the Flapjack engine-identity lane.
    # FIXME(migration-facade-split): extract migration test/support helpers and
    # remove this override.
    "infra/api/src/services/migration/mod.rs|880|temporary cap for pre-existing merge-target migration facade overage; split pending"

    # 2026-07-09: this web owner is still 813 lines, above the
    # generic 700-line .svelte fallback. Keep only a narrow temporary cap
    # while the existing split/removal lane extracts tab surface area.
    # FIXME(stage9-web-owners-split): split this file into focused modules/components
    # and remove this override.
    "web/src/routes/console/indexes/[name]/IndexDetailShell.svelte|828|temporary cap while index-detail tabs are extracted; split pending"

    # 2026-07-19: the migration console wizard landed at 748 lines, above the
    # generic 700-line .svelte fallback (jul13_9pm_10 lane closed on the
    # migration-flow-size-gate blocker; main had this owner at 671).
    # FIXME(migration-create-flow-split): extract wizard step components
    # and remove this override.
    "web/src/lib/components/migration/MigrationCreateFlow.svelte|760|temporary cap while create-flow wizard steps are extracted; split pending"

)

check_file_size() {
    local file="$1"
    local line_count limit relative_path override_entry override_path override_limit

    line_count="$(wc -l < "$file" | tr -d ' ')"
    limit=850
    if [[ "$file" == *.svelte ]]; then
        limit=700
    fi

    relative_path="${file#"$BASE_DIR"/}"

    # Apply per-file override if present. Linear scan is fine — the list
    # is intended to stay tiny and the file count is bounded.
    for override_entry in "${PER_FILE_OVERRIDES[@]}"; do
        override_path="${override_entry%%|*}"
        if [[ "$relative_path" == "$override_path" ]]; then
            override_limit="${override_entry#*|}"
            override_limit="${override_limit%%|*}"
            limit="$override_limit"
            break
        fi
    done

    if (( line_count > limit )); then
        echo "FAIL: ${relative_path} (${line_count} lines, limit ${limit})"
        violation_count=$((violation_count + 1))
    fi
}

for scan_dir in "${SCAN_DIRS[@]}"; do
    absolute_scan_dir="$BASE_DIR/$scan_dir"
    if [[ ! -d "$absolute_scan_dir" ]]; then
        continue
    fi

    while IFS= read -r source_file; do
        check_file_size "$source_file"
    done < <(
        find "$absolute_scan_dir" \
            \( -type d -name tests -o -type d -name node_modules \) -prune -o \
            -type f \( -name "*.rs" -o -name "*.ts" -o -name "*.svelte" \) -print | sort
    )
done

if (( violation_count > 0 )); then
    exit 1
fi
