#!/usr/bin/env bash
# Stage 1 gate for Stripe restricted-key cutover prerequisites.
#
# This script is intentionally non-mutating. It validates that operator-managed
# prerequisites exist in the configured secret source and emits redacted
# evidence for downstream stages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SECRET_FILE="$REPO_ROOT/.secret/.env.secret"
DEFAULT_EVIDENCE_ROOT="$REPO_ROOT/docs/runbooks/evidence/secret-rotation"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

SECRET_SOURCE="${FJCLOUD_SECRET_FILE:-$DEFAULT_SECRET_FILE}"
EVIDENCE_DIR="${STRIPE_CUTOVER_EVIDENCE_DIR:-}"
UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPO_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
STATUS_DOC=""
ACTION_DOC=""

comment_marker_value() {
    local marker_name="$1"
    local value
    value="$(
        grep -E "^[[:space:]]*#[[:space:]]*${marker_name}=" "$SECRET_SOURCE" 2>/dev/null \
            | tail -n 1 \
            | sed -E "s/^[[:space:]]*#[[:space:]]*${marker_name}=//"
    )"
    printf '%s\n' "${value#"${value%%[![:space:]]*}"}"
}

ensure_evidence_dir() {
    if [ -z "$EVIDENCE_DIR" ]; then
        EVIDENCE_DIR="${DEFAULT_EVIDENCE_ROOT}/${UTC_STAMP}_stripe_cutover"
    fi
    mkdir -p "$EVIDENCE_DIR"
    STATUS_DOC="$EVIDENCE_DIR/PREREQUISITE_STATUS.md"
    ACTION_DOC="$EVIDENCE_DIR/OPERATOR_ACTION_REQUIRED.md"
}

write_status_doc() {
    local result="$1"
    local restricted_key_state="$2"
    local restricted_id_marker_state="$3"
    local old_key_marker_state="$4"

    cat > "$STATUS_DOC" <<EOF
# Stripe Cutover Prerequisite Status

- Generated UTC: $UTC_STAMP
- Repo SHA: $REPO_SHA
- Secret source: $SECRET_SOURCE
- Result: $result

## Required Inputs

- STRIPE_SECRET_KEY_RESTRICTED: $restricted_key_state
- STRIPE_RESTRICTED_KEY_ID: $restricted_id_marker_state
- STRIPE_OLD_KEY_ID: $old_key_marker_state
EOF
}

write_operator_action_doc() {
    local missing_items=("$@")
    local missing_item

    {
        echo "# Operator Action Required — Stripe cutover prerequisites"
        echo
        echo "The Stage 1 prerequisite gate failed. Update the operator secret source and re-run:"
        echo "FJCLOUD_SECRET_FILE=\"\${FJCLOUD_SECRET_FILE:-.secret/.env.secret}\" bash scripts/stripe_cutover_prereqs.sh"
        echo
        echo "Secret source: $SECRET_SOURCE"
        echo "Generated UTC: $UTC_STAMP"
        echo "Repo SHA: $REPO_SHA"
        echo
        echo "Missing inputs:"
        for missing_item in "${missing_items[@]}"; do
            echo "- $missing_item"
        done
    } > "$ACTION_DOC"
}

run_prerequisite_checks() {
    local restricted_key_state="missing"
    local restricted_id_marker_state="missing"
    local old_key_marker_state="missing"
    local restricted_id_marker
    local old_key_marker
    local missing_items=()

    if [ ! -f "$SECRET_SOURCE" ]; then
        missing_items+=("Secret source file not found: $SECRET_SOURCE")
    fi

    # Keep load_env_file as the single parser owner for KEY=value assignments.
    load_env_file "$SECRET_SOURCE"

    if [ -n "${STRIPE_SECRET_KEY_RESTRICTED:-}" ]; then
        restricted_key_state="present"
    else
        missing_items+=("STRIPE_SECRET_KEY_RESTRICTED is missing")
    fi

    restricted_id_marker="$(comment_marker_value "STRIPE_RESTRICTED_KEY_ID")"
    if [ -n "$restricted_id_marker" ]; then
        restricted_id_marker_state="present"
    else
        missing_items+=("Comment marker is missing: # STRIPE_RESTRICTED_KEY_ID=<stripe_key_id>")
    fi

    old_key_marker="$(comment_marker_value "STRIPE_OLD_KEY_ID")"
    if [ -n "$old_key_marker" ]; then
        old_key_marker_state="present"
    else
        missing_items+=("Comment marker is missing: # STRIPE_OLD_KEY_ID=<stripe_key_id>")
    fi

    if [ "${#missing_items[@]}" -gt 0 ]; then
        write_status_doc "failed" "$restricted_key_state" "$restricted_id_marker_state" "$old_key_marker_state"
        write_operator_action_doc "${missing_items[@]}"
        echo "REASON: prerequisite_missing" >&2
        return 1
    fi

    write_status_doc "passed" "$restricted_key_state" "$restricted_id_marker_state" "$old_key_marker_state"
    rm -f "$ACTION_DOC"
    echo "PREREQUISITES_OK evidence_dir=$EVIDENCE_DIR"
}

ensure_evidence_dir
run_prerequisite_checks
