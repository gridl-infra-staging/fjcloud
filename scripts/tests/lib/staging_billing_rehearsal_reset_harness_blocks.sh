#!/usr/bin/env bash
# Script blocks consumed by staging_billing_rehearsal_harness.sh reset tests.

# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
# TODO: Document mock_psql_reset_script_block.
mock_psql_reset_script_block() {
    cat <<'MOCK'
if [[ "$sql" == *"stage4_reset_customer_lookup"* ]]; then
    case "${REHEARSAL_MOCK_RESET_CUSTOMER_LOOKUP_MODE:-found}" in
        missing)
            ;;
        empty_stripe)
            printf '\n'
            ;;
        *)
            printf '%s\n' "${REHEARSAL_MOCK_RESET_CUSTOMER_STRIPE_ID:-cus_reset_test}"
            ;;
    esac
    exit 0
fi

if [[ "$sql" == *"stage4_reset_invoice_rows"* ]]; then
    mode="${REHEARSAL_MOCK_RESET_INVOICE_ROWS_MODE:-mixed_statuses}"
    deleted_ids="$(cat "$RESET_DELETED_FILE" 2>/dev/null || true)"

    is_reset_deleted() {
        local stripe_id="$1"
        [ -n "$stripe_id" ] || return 1
        printf '%s\n' "$deleted_ids" | grep -Fxq "$stripe_id"
    }

    emit_reset_row() {
        local invoice_id="$1"
        local stripe_id="$2"
        if ! is_reset_deleted "$stripe_id"; then
            printf '%s|%s\n' "$invoice_id" "$stripe_id"
        fi
    }

    case "$mode" in
        none)
            ;;
        clearable_trio)
            emit_reset_row "inv_local_reset_draft" "si_reset_draft"
            emit_reset_row "inv_local_reset_open" "si_reset_open"
            emit_reset_row "inv_local_reset_uncollectible" "si_reset_uncollectible"
            ;;
        paid_only)
            emit_reset_row "inv_local_reset_paid" "si_reset_paid"
            ;;
        paid_without_stripe_id)
            emit_reset_row "inv_local_reset_paid_missing_stripe" ""
            ;;
        draft_without_stripe_id)
            emit_reset_row "inv_local_reset_draft_missing_stripe" ""
            ;;
        draft_and_missing_status)
            emit_reset_row "inv_local_reset_draft" "si_reset_draft"
            emit_reset_row "inv_local_reset_missing" "si_reset_missing"
            ;;
        mixed_statuses|*)
            emit_reset_row "inv_local_reset_draft" "si_reset_draft"
            emit_reset_row "inv_local_reset_open" "si_reset_open"
            emit_reset_row "inv_local_reset_uncollectible" "si_reset_uncollectible"
            emit_reset_row "inv_local_reset_paid" "si_reset_paid"
            ;;
    esac
    exit 0
fi

if [[ "$sql" == *"stage4_reset_delete_invoices"* ]]; then
    python3 - "$sql" "$RESET_DELETED_FILE" <<'PY'
import pathlib
import re
import sys

sql = sys.argv[1]
deleted_file = pathlib.Path(sys.argv[2])
existing = []
if deleted_file.exists():
    existing = [line.strip() for line in deleted_file.read_text(encoding="utf-8").splitlines() if line.strip()]

ids = re.findall(r"'([^']+)'", sql)
for stripe_id in ids:
    if stripe_id not in existing:
        existing.append(stripe_id)

deleted_file.write_text("\n".join(existing) + ("\n" if existing else ""), encoding="utf-8")
print(len(ids))
PY
    exit 0
fi
MOCK
}

mock_stripe_reset_script_block() {
    cat <<'MOCK'
if [ "${1:-}" = "invoices" ] && [ "${2:-}" = "list" ]; then
    forced_exit="${REHEARSAL_MOCK_STRIPE_LIST_EXIT:-0}"
    if [ "$forced_exit" -ne 0 ]; then
        exit "$forced_exit"
    fi
    if [ -n "${REHEARSAL_MOCK_STRIPE_LIST_JSON:-}" ]; then
        printf '%s\n' "$REHEARSAL_MOCK_STRIPE_LIST_JSON"
    else
        printf '%s\n' '{"data":[]}'
    fi
    exit 0
fi

if [ "${1:-}" = "invoices" ] && [ "${2:-}" = "delete" ]; then
    invoice_id="${3:-}"
    case ",${REHEARSAL_MOCK_STRIPE_DELETE_FAIL_IDS:-}," in
        *,"${invoice_id}",*)
            exit 1
            ;;
    esac
    exit 0
fi

if [ "${1:-}" = "invoices" ] && [ "${2:-}" = "void" ]; then
    invoice_id="${3:-}"
    case ",${REHEARSAL_MOCK_STRIPE_VOID_FAIL_IDS:-}," in
        *,"${invoice_id}",*)
            exit 1
            ;;
    esac
    exit 0
fi

exit "${REHEARSAL_MOCK_STRIPE_DEFAULT_EXIT:-0}"
MOCK
}
