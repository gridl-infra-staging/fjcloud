#!/usr/bin/env bash

# Contract test: every Stripe catalog dimension must be a real rate-card field,
# and rate-card minimums retired from invoice-floor computation must not remain
# in the emitted catalog plan.
#
# This test is intentionally static. Sourcing create_catalog.sh would resolve a
# Stripe key and call Stripe, so the catalog array is parsed as text instead.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG_SCRIPT="$REPO_ROOT/scripts/stripe/create_catalog.sh"
RATE_CARD_MODEL="$REPO_ROOT/infra/api/src/models/rate_card.rs"
FLOOR_OWNER="$REPO_ROOT/infra/api/src/invoicing/line_items.rs"
ZERO_MINIMUM_MIGRATION="$REPO_ROOT/infra/migrations/049_free_plan_zero_minimum_spend.sql"

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

for required_file in \
    "$CATALOG_SCRIPT" \
    "$RATE_CARD_MODEL" \
    "$FLOOR_OWNER" \
    "$ZERO_MINIMUM_MIGRATION"; do
    [ -r "$required_file" ] || {
        printf 'FAIL: cannot read %s\n' "$required_file"
        exit 1
    }
done

# Read only the quoted CATALOG array entries. This does not execute the script,
# resolve a secret, make a network call, or mutate a Stripe account.
catalog_rows="$(sed -n '/^CATALOG=(/,/^)/ {
    s/^[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p
}' "$CATALOG_SCRIPT")"

catalog_count="$(printf '%s\n' "$catalog_rows" | grep -c .)"

# RateCardRow is the owner of valid database rate columns. Only structural
# fields are excluded here; pricing dimensions are discovered from the struct,
# not copied into this test.
rate_card_fields="$(sed -n '/^pub struct RateCardRow {/,/^}/p' "$RATE_CARD_MODEL" \
    | sed -n 's/^[[:space:]]*pub \([a-z_][a-z0-9_]*\):.*/\1/p')"
accepted_dimensions="$(printf '%s\n' "$rate_card_fields" \
    | grep -Ev '^(id|name|effective_from|effective_until|region_multipliers|created_at)$' || true)"

# This is the sole catalog exception: the column remains for historical row
# compatibility, but the invoice-floor owner and migration below prove that it
# is retired. Every other pricing dimension must be emitted exactly once.
retired_floor_dimensions="minimum_spend_cents"
active_catalog_dimensions="$accepted_dimensions"
while IFS= read -r retired_dimension; do
    [ -n "$retired_dimension" ] || continue
    active_catalog_dimensions="$(printf '%s\n' "$active_catalog_dimensions" \
        | grep -Fxv -- "$retired_dimension" || true)"
done <<EOF
$retired_floor_dimensions
EOF

if [ -n "$accepted_dimensions" ]; then
    pass "extracted accepted catalog dimensions from RateCardRow: $(printf '%s' "$accepted_dimensions" | tr '\n' ' ')"
else
    fail "could not extract accepted catalog dimensions from RateCardRow"
fi

active_dimension_count="$(printf '%s\n' "$active_catalog_dimensions" | grep -c .)"
if [ "$catalog_count" -eq "$active_dimension_count" ]; then
    pass "catalog row count matches $active_dimension_count active RateCardRow dimensions"
else
    fail "catalog has $catalog_count rows; expected $active_dimension_count active RateCardRow dimensions"
fi

# Every emitted dimension must remain a valid field, and a malformed row must
# not disappear behind the membership check. Failures name the dimension and
# product so operators can identify the drifting catalog object directly.
while IFS='|' read -r dim_key product_name _rest; do
    [ -n "$dim_key$product_name" ] || continue
    if [ -z "$dim_key" ] || [ -z "$product_name" ]; then
        fail "malformed catalog row has dimension '$dim_key' and product '$product_name'"
    elif printf '%s\n' "$accepted_dimensions" | grep -Fxq -- "$dim_key"; then
        pass "catalog dimension '$dim_key' for product '$product_name' is a RateCardRow field"
    else
        fail "catalog dimension '$dim_key' for product '$product_name' is not a RateCardRow field"
    fi
done <<EOF
$catalog_rows
EOF

while IFS= read -r active_dimension; do
    [ -n "$active_dimension" ] || continue
    emitted_count="$(printf '%s\n' "$catalog_rows" \
        | cut -d '|' -f 1 \
        | grep -Fxc -- "$active_dimension" || true)"
    if [ "$emitted_count" -eq 1 ]; then
        pass "active catalog dimension '$active_dimension' is emitted exactly once"
    elif [ "$emitted_count" -eq 0 ]; then
        fail "active catalog dimension '$active_dimension' is missing"
    else
        fail "active catalog dimension '$active_dimension' is emitted $emitted_count times"
    fi
done <<EOF
$active_catalog_dimensions
EOF

# invoice_total_with_minimum is the behavioral owner for dimensions that still
# affect invoice floors. Pin both branches before using it as an exclusion
# oracle: Shared reads its named rate-card field, while Free uses literal zero.
floor_function="$(sed -n '/^pub(super) fn invoice_total_with_minimum(/,/^}/p' "$FLOOR_OWNER")"
floor_dimensions="$(printf '%s\n' "$floor_function" \
    | grep -Eo 'rate_card\.[a-z_][a-z0-9_]*' \
    | sed 's/^rate_card\.//' || true)"

if printf '%s\n' "$floor_function" | grep -Eq 'BillingPlan::Free[[:space:]]*=>[[:space:]]*0,'; then
    pass "invoice_total_with_minimum applies a literal zero floor to BillingPlan::Free"
else
    fail "invoice_total_with_minimum no longer applies a literal zero floor to BillingPlan::Free"
fi

if printf '%s\n' "$floor_function" \
    | grep -Eq 'BillingPlan::Shared[[:space:]]*=>[[:space:]]*rate_card\.shared_minimum_spend_cents,'; then
    pass "invoice_total_with_minimum reads shared_minimum_spend_cents for BillingPlan::Shared"
else
    fail "invoice_total_with_minimum no longer reads shared_minimum_spend_cents for BillingPlan::Shared"
fi

if grep -Eq 'SET[[:space:]]+minimum_spend_cents[[:space:]]*=[[:space:]]*0' \
    "$ZERO_MINIMUM_MIGRATION"; then
    pass "migration 049 pins the launch minimum_spend_cents value to zero"
else
    fail "migration 049 no longer pins the launch minimum_spend_cents value to zero"
fi

while IFS= read -r retired_dimension; do
    [ -n "$retired_dimension" ] || continue

    if ! printf '%s\n' "$accepted_dimensions" | grep -Fxq -- "$retired_dimension"; then
        fail "retired invoice-floor dimension '$retired_dimension' is not a valid RateCardRow field"
        continue
    fi

    if printf '%s\n' "$floor_dimensions" | grep -Fxq -- "$retired_dimension"; then
        fail "retired invoice-floor dimension '$retired_dimension' is still read by invoice_total_with_minimum"
        continue
    fi

    emitted=0
    while IFS='|' read -r dim_key product_name _rest; do
        [ -n "$dim_key$product_name" ] || continue
        if [ "$dim_key" = "$retired_dimension" ]; then
            emitted=1
            fail "retired invoice-floor dimension '$dim_key' is still emitted for product '$product_name'"
        fi
    done <<EOF
$catalog_rows
EOF

    if [ "$emitted" -eq 0 ]; then
        pass "retired invoice-floor dimension '$retired_dimension' is absent from the Stripe catalog"
    fi
done <<EOF
$retired_floor_dimensions
EOF

printf '\n=== Results: %d passed, %d failed; catalog rows checked: %d ===\n' \
    "$PASS" "$FAIL" "$catalog_count"
[ "$FAIL" -eq 0 ]
