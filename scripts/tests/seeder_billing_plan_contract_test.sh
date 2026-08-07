#!/usr/bin/env bash

# Contract test: every billing plan the synthetic-traffic seeder sends must be a
# plan the API actually accepts.
#
# WHY THIS EXISTS. The seeder PUTs {"billing_plan":"<plan>"} to
# /admin/tenants/<id> (seed_synthetic_traffic.sh, "update_payload"), and the
# handler parses it with BillingPlan::from_str, returning 400 for anything not in
# the enum. The seeder shipped TENANT_B_PLAN and TENANT_C_PLAN as "dedicated",
# a value that appears nowhere in infra/api/src -- so the seeder died on tenant B
# with `update tenant failed ... status=400` after tenant A had already been
# provisioned and written to. That is a fatal `die`, not a warning, and it burns a
# live staging soak every time.
#
# The two sides live in different languages and neither imports the other, so
# nothing detected the drift. This test is the seam: it reads the accepted set
# from BillingPlan::from_str -- the actual acceptance oracle, not a hand-copied
# list -- and requires every seeder plan to be a member.
#
# NOT IN SCOPE HERE: whether the seeder's EXPECTED_MIN_CENTS labels match the live
# rate card. Those are log-only (seed_synthetic_traffic.sh prints them as
# "expected floor" and asserts nothing), and rate-card value drift is owned by the
# pricing-owner lane. This test deliberately checks acceptance, not pricing, so it
# stays a contract test rather than a second pricing authority.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CUSTOMER_MODEL="$REPO_ROOT/infra/api/src/models/customer.rs"
SEEDER="$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh"

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -r "$CUSTOMER_MODEL" ] || { printf 'FAIL: cannot read %s\n' "$CUSTOMER_MODEL"; exit 1; }
[ -r "$SEEDER" ]         || { printf 'FAIL: cannot read %s\n' "$SEEDER"; exit 1; }

# Extract the accepted plan strings from BillingPlan::from_str's match arms. This
# is the acceptance oracle the API itself uses, so the test cannot pass while the
# API would reject the value.
accepted="$(sed -n '/fn from_str/,/^    }/p' "$CUSTOMER_MODEL" \
    | sed -n 's/^[[:space:]]*"\([a-z_]*\)" => Ok(Self::.*/\1/p')"

if [ -z "$accepted" ]; then
    fail "could not extract any accepted billing plans from BillingPlan::from_str"
    printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
    exit 1
fi
pass "extracted the accepted billing-plan set from BillingPlan::from_str: $(printf '%s' "$accepted" | tr '\n' ' ')"

# Extract every plan the seeder is configured to send.
seeder_plans="$(sed -n 's/^TENANT_\([A-Z]\)_PLAN="\([a-z_]*\)".*/\1 \2/p' "$SEEDER")"

if [ -z "$seeder_plans" ]; then
    fail "could not extract any TENANT_*_PLAN values from the seeder"
    printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
    exit 1
fi

# Guard the extractor itself: if the seeder's tenant block is ever restructured
# so the regex silently matches nothing, a vacuous pass would look identical to a
# real one. The seeder defines tenants A, B and C.
seeder_count="$(printf '%s\n' "$seeder_plans" | grep -c .)"
if [ "$seeder_count" -ge 3 ]; then
    pass "extracted $seeder_count seeder tenant plans (expected at least 3)"
else
    fail "extracted only $seeder_count seeder tenant plans; the extractor has gone stale"
fi

# The actual contract.
while read -r letter plan; do
    [ -n "$plan" ] || continue
    if printf '%s\n' "$accepted" | grep -Fxq -- "$plan"; then
        pass "tenant $letter plan '$plan' is accepted by BillingPlan::from_str"
    else
        fail "tenant $letter plan '$plan' is NOT accepted by BillingPlan::from_str (accepted: $(printf '%s' "$accepted" | tr '\n' ' ')); the admin tenant update will return 400 and the seeder will die"
    fi
done <<EOF
$seeder_plans
EOF

printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
