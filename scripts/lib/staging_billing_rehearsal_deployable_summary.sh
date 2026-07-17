#!/usr/bin/env bash
# Deployable-currency summary helpers for staging billing rehearsal.

read_key_value_field() {
    local body="$1"
    local key="$2"
    local line

    while IFS= read -r line; do
        case "$line" in
            "$key="*)
                printf '%s\n' "${line#*=}"
                return
                ;;
        esac
    done <<< "$body"
    printf 'unknown\n'
}

summary_deployable_currency_json() {
    local deployable_drift="$1"
    local doc_only_ahead="$2"
    python3 - "$deployable_drift" "$doc_only_ahead" <<'PY' || true
import json
import sys

def parse_bool(value):
    if value == "true":
        return True
    if value == "false":
        return False
    return None

print(json.dumps({
    "deployable_drift": parse_bool(sys.argv[1]),
    "doc_only_ahead": parse_bool(sys.argv[2]),
}))
PY
}

capture_summary_deployable_currency() {
    local version_url body dev_main_sha currency_output deployable_drift doc_only_ahead

    if [ "${CAPTURE_SUMMARY_DEPLOYABLE_CURRENCY:-0}" -ne 1 ]; then
        return
    fi
    if [ -z "${STAGING_API_URL:-}" ]; then
        return
    fi
    version_url="${STAGING_API_URL%/}/version"
    body="$(curl -fsS --max-time 5 "$version_url" 2>/dev/null || true)"
    if ! is_valid_json "$body"; then
        return
    fi
    SUMMARY_DEV_SHA="$(validation_json_get_field "$body" "dev_sha")"
    [ -n "$SUMMARY_DEV_SHA" ] || SUMMARY_DEV_SHA="unknown"
    dev_main_sha="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null \
        || git -C "$REPO_ROOT" rev-parse main 2>/dev/null \
        || git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null \
        || printf '%s\n' "$SUMMARY_DEV_SHA")"
    currency_output="$(classify_deployable_currency "$REPO_ROOT" "$SUMMARY_DEV_SHA" "$dev_main_sha" 2>/dev/null || true)"
    deployable_drift="$(read_key_value_field "$currency_output" "deployable_drift")"
    doc_only_ahead="$(read_key_value_field "$currency_output" "doc_only_ahead")"
    SUMMARY_DEPLOYABLE_CURRENCY_JSON="$(summary_deployable_currency_json "$deployable_drift" "$doc_only_ahead")"
}
