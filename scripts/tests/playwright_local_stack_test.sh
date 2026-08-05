#!/usr/bin/env bash
# Dispatcher for the Playwright local stack shell suites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

child_suite_status=0
for child_suite in \
	playwright_local_stack_flapjack_test.sh \
	playwright_local_stack_web_reclaim_test.sh \
	playwright_local_stack_core_test.sh; do
	if ! bash "$SCRIPT_DIR/$child_suite"; then
		child_suite_status=1
	fi
done

exit "$child_suite_status"
