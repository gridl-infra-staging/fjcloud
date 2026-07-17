#!/usr/bin/env bash
# Canonical browser-path probe for the Overview export/import contract.
# Runs the focused Playwright owner and records a machine-readable verdict at:
#   docs/runbooks/evidence/index-export-clientside/<UTC>/summary.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_ROOT="$REPO_ROOT/docs/runbooks/evidence/index-export-clientside"
RUN_DIR="$EVIDENCE_ROOT/$RUN_UTC"
SUMMARY_PATH="$RUN_DIR/summary.json"
PLAYWRIGHT_LOG_PATH="$RUN_DIR/playwright.log"
PLAYWRIGHT_VERDICT_PATH="$(mktemp "${TMPDIR:-/tmp}/overview_export_probe_verdict.XXXXXX.json")"
PLAYWRIGHT_COMMAND='cd web && npx playwright test tests/e2e-ui/full/overview_enrichment.spec.ts --project=chromium'

cleanup() {
	rm -f "$PLAYWRIGHT_VERDICT_PATH"
}
trap cleanup EXIT

mkdir -p "$RUN_DIR"

playwright_exit_status=0
set +e
(
	cd "$REPO_ROOT/web" && \
		OVERVIEW_EXPORT_PROBE_VERDICT_PATH="$PLAYWRIGHT_VERDICT_PATH" \
		npx playwright test tests/e2e-ui/full/overview_enrichment.spec.ts --project=chromium
) >"$PLAYWRIGHT_LOG_PATH" 2>&1
playwright_exit_status=$?
set -e

export_filename_verdict="false"
export_payload_verdict="false"
import_banner_verdict="false"
if [[ -f "$PLAYWRIGHT_VERDICT_PATH" ]]; then
	export_filename_verdict="$(python3 - <<'PY' "$PLAYWRIGHT_VERDICT_PATH"
import json, sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("true" if payload.get("export_filename_verdict") is True else "false")
PY
)"
	export_payload_verdict="$(python3 - <<'PY' "$PLAYWRIGHT_VERDICT_PATH"
import json, sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("true" if payload.get("export_payload_verdict") is True else "false")
PY
)"
	import_banner_verdict="$(python3 - <<'PY' "$PLAYWRIGHT_VERDICT_PATH"
import json, sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("true" if payload.get("import_banner_verdict") is True else "false")
PY
)"
fi

overall_verdict="fail"
if [[ "$playwright_exit_status" == "0" && "$export_filename_verdict" == "true" && "$export_payload_verdict" == "true" && "$import_banner_verdict" == "true" ]]; then
	overall_verdict="pass"
fi

cat > "$SUMMARY_PATH" <<EOF
{
  "run_utc": "$RUN_UTC",
  "playwright_command": "$PLAYWRIGHT_COMMAND",
  "playwright_exit_status": $playwright_exit_status,
  "export_filename_verdict": $export_filename_verdict,
  "export_payload_verdict": $export_payload_verdict,
  "import_banner_verdict": $import_banner_verdict,
  "overall_verdict": "$overall_verdict",
  "playwright_log_path": "playwright.log"
}
EOF

echo "summary_json=$SUMMARY_PATH"
if [[ "$overall_verdict" != "pass" ]]; then
	echo "FAIL: overview browser contract drift (see $SUMMARY_PATH and $PLAYWRIGHT_LOG_PATH)" >&2
	exit 1
fi
echo "PASS: overview browser contract probe"
