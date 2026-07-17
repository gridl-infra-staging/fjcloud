#!/usr/bin/env bash
# Static cross-file regression guard for the SES configuration-set + IAM
# coupling that was a silent launch blocker on 2026-04-30:
#
#   `infra/api/src/services/email.rs::SesEmailService::send_html_email` calls
#   `.configuration_set_name(...)` on every outbound SES SendEmail. SES
#   authorises SendEmail against BOTH the identity ARN AND the
#   configuration-set ARN as separate resources. The instance role's
#   `fjcloud-ses-send` inline policy in `ops/iam/fjcloud-instance-role.tf`
#   originally granted only the identity, so every staging SES send was
#   silently denied for ~36 hours starting at commit d8c81ce7.
#
# The bug surfaced via a probe (broadcast returned `failure_count=22,
# success_count=0`) but no test caught it because:
#   - Unit tests use MockEmailService, not the live SES client.
#   - No static contract test linked the code's configuration_set_name use
#     to the IAM policy's configuration-set ARN grant.
#
# This test enforces the contract: if email.rs attaches a configuration set
# to SES sends, the IAM policy MUST grant ses:SendEmail on a matching
# configuration-set/* ARN. The two halves must move together.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EMAIL_RS="$REPO_ROOT/infra/api/src/services/email.rs"
IAM_TF="$REPO_ROOT/ops/iam/fjcloud-instance-role.tf"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# Sanity preconditions — both files must exist where this contract expects.
[ -r "$EMAIL_RS" ] || { echo "ERROR: cannot read $EMAIL_RS" >&2; exit 2; }
[ -r "$IAM_TF" ] || { echo "ERROR: cannot read $IAM_TF" >&2; exit 2; }

# Count active (non-comment) call sites that attach a configuration set on
# the SES SendEmail builder. Inline `//` comments and full-line `//` comments
# are stripped first so a future doc-only mention of the API doesn't trip the
# guard. The pattern is intentionally narrow: only the SDK builder method
# `.configuration_set_name(` triggers the coupling, not any string literal
# that happens to contain those words.
configset_call_count=$(
    sed -E 's|//.*$||' "$EMAIL_RS" \
        | grep -cE '\.configuration_set_name\s*\(' \
        || true
)

# Count active (non-comment) IAM resource ARNs that grant
# `configuration-set/...`. HCL line-comments are `#` or `//`. We strip both
# so the comment block above the policy doesn't trigger a false positive.
iam_configset_arn_count=$(
    sed -E 's|#.*$||; s|//.*$||' "$IAM_TF" \
        | grep -cE 'configuration-set/' \
        || true
)

# True coupling assertion: either both halves are present (current state) or
# both are absent (a future refactor that removes the configset attach can
# also drop the IAM grant safely). Any one-sided state is the bug class we're
# guarding against.
if [ "$configset_call_count" -gt 0 ] && [ "$iam_configset_arn_count" -gt 0 ]; then
    pass "configuration_set_name() in email.rs is matched by configuration-set/* ARN in fjcloud-ses-send IAM policy"
elif [ "$configset_call_count" -eq 0 ] && [ "$iam_configset_arn_count" -eq 0 ]; then
    pass "neither side attaches a configuration set; coupling consistent (no IAM grant needed)"
else
    fail "SES configuration_set_name attach and IAM grant are out of sync. \
configset_call_count=$configset_call_count in $EMAIL_RS, iam_configset_arn_count=$iam_configset_arn_count in $IAM_TF. \
Either email.rs attaches a configuration set without IAM granting it (silent prod denial) \
or the IAM grant exists without a code consumer (dead permission). \
Re-align the two before merging — see docs/runbooks/evidence/ses-deliverability/20260430T234448Z_bounce_e2e_probe/SUMMARY.md \
for the original incident write-up."
fi

# Belt-and-braces: also assert the identity ARN remains in the policy, since
# SES SendEmail always requires identity-level authorization regardless of
# whether a configuration set is attached. A future refactor that drops the
# identity ARN and keeps only the configuration-set ARN would still break
# email sending for a different reason.
if grep -qE 'identity/flapjack\.foo' "$IAM_TF"; then
    pass "fjcloud-ses-send still grants the identity/flapjack.foo ARN"
else
    fail "fjcloud-ses-send no longer grants identity/flapjack.foo. SES SendEmail authorisation always requires the identity-level grant; without it, every send will be denied."
fi

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
