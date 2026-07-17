#!/usr/bin/env bash
# Validate the doc-system v2 root/doc-directory surface against the checked-in allowlist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_DOC_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ALLOWLIST_PATH="$REPO_ROOT/.scrai/allowed_top_docs.txt"
ALLOWLIST_DISPLAY_PATH=".scrai/allowed_top_docs.txt"

if [ ! -f "$ALLOWLIST_PATH" ]; then
    echo "FAIL: $ALLOWLIST_DISPLAY_PATH not found at $ALLOWLIST_PATH" >&2
    exit 1
fi

python3 - "$REPO_ROOT" "$ALLOWLIST_PATH" "$ALLOWLIST_DISPLAY_PATH" <<'PY'
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
allowlist_path = pathlib.Path(sys.argv[2])
allowlist_display_path = sys.argv[3]

allowed = {
    line.strip()
    for line in allowlist_path.read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.startswith("#")
}

actual = {path.name for path in repo_root.glob("*.md")}

allowed_doc_dirs = {entry for entry in allowed if entry.startswith("docs/") and entry.endswith("/")}

unexpected = sorted(actual - allowed)
missing = sorted(
    entry
    for entry in allowed
    if not entry.endswith("/") and not (repo_root / entry).is_file()
)
missing.extend(
    sorted(entry for entry in allowed_doc_dirs if not (repo_root / entry).is_dir())
)

for entry in unexpected:
    print(f"FAIL: unexpected doc surface {entry}")
for entry in missing:
    print(f"FAIL: allowlisted doc is missing {entry}")

if unexpected or missing:
    raise SystemExit(1)

print(f"OK: doc surface matches {allowlist_display_path}")
PY
