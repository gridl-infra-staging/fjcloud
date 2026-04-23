#!/usr/bin/env bash
# Enforce hard file-size limits for source files.

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

check_file_size() {
    local file="$1"
    local line_count limit relative_path

    line_count="$(wc -l < "$file" | tr -d ' ')"
    limit=800
    if [[ "$file" == *.svelte ]]; then
        limit=600
    fi

    if (( line_count > limit )); then
        relative_path="${file#"$BASE_DIR"/}"
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
