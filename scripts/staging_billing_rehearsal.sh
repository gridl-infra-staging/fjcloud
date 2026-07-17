#!/usr/bin/env bash
# staging_billing_rehearsal.sh — guarded staging billing mutation rehearsal.

set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RUNNER_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$RUNNER_DIR/lib/env.sh"
# shellcheck source=lib/validation_json.sh
source "$RUNNER_DIR/lib/validation_json.sh"
# shellcheck source=lib/live_gate.sh
source "$RUNNER_DIR/lib/live_gate.sh"
# shellcheck source=lib/metering_checks.sh
source "$RUNNER_DIR/lib/metering_checks.sh"
# shellcheck source=lib/billing_rehearsal_steps.sh
source "$RUNNER_DIR/lib/billing_rehearsal_steps.sh"
# shellcheck source=lib/rc_invocation.sh
source "$RUNNER_DIR/lib/rc_invocation.sh"
# shellcheck source=lib/staging_billing_rehearsal_flow.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_flow.sh"
# shellcheck source=lib/staging_billing_rehearsal_deployable_summary.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_deployable_summary.sh"
# shellcheck source=lib/staging_billing_rehearsal_evidence.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_evidence.sh"
# shellcheck source=lib/staging_billing_rehearsal_cross_check.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_cross_check.sh"
# shellcheck source=lib/staging_billing_rehearsal_email_evidence.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_email_evidence.sh"
# shellcheck source=lib/staging_billing_rehearsal_metering.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_metering.sh"
# shellcheck source=lib/staging_billing_rehearsal_live_mutation.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_live_mutation.sh"
# shellcheck source=lib/stripe_request.sh
source "$RUNNER_DIR/lib/stripe_request.sh"
# shellcheck source=lib/deployable_currency.sh
source "$RUNNER_DIR/lib/deployable_currency.sh"
# shellcheck source=lib/staging_billing_rehearsal_reset.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_reset.sh"
# shellcheck source=lib/staging_billing_rehearsal_impl.sh
source "$RUNNER_DIR/lib/staging_billing_rehearsal_impl.sh"

parse_args() {
    parse_args_impl "$@"
}

main() {
    staging_billing_rehearsal_main_impl "$@"
}

main "$@"
