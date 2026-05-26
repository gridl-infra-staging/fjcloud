#!/usr/bin/env bash
set -euo pipefail

RUNBOOK_PATH="docs/runbooks/support_email_probe.md"

if [[ ! -f "$RUNBOOK_PATH" ]]; then
    echo "ERROR: missing operator runbook $RUNBOOK_PATH" >&2
    exit 3
fi

echo "Operator-only probe delegated to $RUNBOOK_PATH"
echo "TERMINUS: operator-only delegation to support_email_probe.md"
exit 0
