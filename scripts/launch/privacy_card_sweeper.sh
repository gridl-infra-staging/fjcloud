#!/usr/bin/env bash
# Close stale lane-scoped Privacy.com cards and emit deterministic summary JSON.
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/privacy_com_client.sh
source "$SCRIPT_DIR/../lib/privacy_com_client.sh"

privacy_card_sweeper_parse_args() {
    PRIVACY_SWEEPER_DRY_RUN="false"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                PRIVACY_SWEEPER_DRY_RUN="true"
                shift
                ;;
            *)
                echo "unknown argument: $1" >&2
                return 2
                ;;
        esac
    done
}

privacy_card_sweeper_client_error() {
    local action="$1"
    local message="${PRIVACY_CLIENT_ERROR_MESSAGE:-privacy.com client error}"
    echo "${action}: ${message}" >&2
}

privacy_card_sweeper_evaluate_page() {
    local json_body="$1"
    local min_age_seconds="$2"
    local sweep_start_epoch="$3"
    shift 3

    python3 - "$json_body" "$min_age_seconds" "$sweep_start_epoch" "$@" <<'PY'
import json
import sys
from datetime import datetime

body = json.loads(sys.argv[1])
min_age_seconds = int(sys.argv[2])
sweep_start_epoch = float(sys.argv[3])
prefixes = tuple(sys.argv[4:])

summary = {
    "candidate_tokens": [],
    "skipped_non_lane": 0,
    "skipped_fresh": 0,
    "total_scanned": 0,
}

for card in body.get("data", []):
    summary["total_scanned"] += 1

    if card.get("state") != "OPEN":
        continue

    memo = card.get("memo")
    if not isinstance(memo, str):
        summary["skipped_non_lane"] += 1
        continue

    if not any(memo.startswith(prefix) for prefix in prefixes):
        summary["skipped_non_lane"] += 1
        continue

    created_raw = card.get("created")
    if not isinstance(created_raw, str):
        summary["skipped_fresh"] += 1
        continue

    created_iso = created_raw.replace("Z", "+00:00")
    try:
        created_epoch = datetime.fromisoformat(created_iso).timestamp()
    except Exception:
        summary["skipped_fresh"] += 1
        continue

    if sweep_start_epoch - created_epoch < min_age_seconds:
        summary["skipped_fresh"] += 1
        continue

    token = card.get("token")
    if isinstance(token, str) and token:
        summary["candidate_tokens"].append(token)

print(json.dumps(summary, separators=(",", ":")))
PY
}

privacy_card_sweeper_tokens_to_json() {
    if [ "$#" -eq 0 ]; then
        echo "[]"
        return 0
    fi

    python3 - "$@" <<'PY'
import json
import sys

values = [value for value in sys.argv[1:] if value]
print(json.dumps(values, separators=(",", ":")))
PY
}

privacy_card_sweeper_emit_summary() {
    local dry_run="$1"
    local pages_scanned="$2"
    local total_scanned="$3"
    local skipped_non_lane="$4"
    local skipped_fresh="$5"
    local candidate_tokens_json="$6"
    local closed_tokens_json="$7"

    python3 - "$dry_run" "$pages_scanned" "$total_scanned" "$skipped_non_lane" "$skipped_fresh" "$candidate_tokens_json" "$closed_tokens_json" <<'PY'
import json
import sys

summary = {
    "dry_run": sys.argv[1] == "true",
    "pages_scanned": int(sys.argv[2]),
    "total_scanned": int(sys.argv[3]),
    "skipped_non_lane": int(sys.argv[4]),
    "skipped_fresh": int(sys.argv[5]),
    "candidate_tokens": json.loads(sys.argv[6]),
    "closed_tokens": json.loads(sys.argv[7]),
}
print(json.dumps(summary, separators=(",", ":")))
PY
}

privacy_card_sweeper_main() {
    privacy_card_sweeper_parse_args "$@"

    if ! privacy_com_require_env; then
        privacy_card_sweeper_client_error "privacy_com_require_env"
        return 1
    fi

    local min_age_seconds="${PRIVACY_SWEEPER_MIN_AGE_SECONDS:-3600}"
    local sweep_start_epoch
    sweep_start_epoch="$(date +%s)"
    local current_page=1
    local total_pages=1
    local pages_scanned=0
    local total_scanned=0
    local skipped_non_lane=0
    local skipped_fresh=0
    local -a candidate_tokens=()
    local -a closed_tokens=()

    while [ "$current_page" -le "$total_pages" ]; do
        if ! privacy_com_list_cards_raw_auth "$current_page" 100; then
            privacy_card_sweeper_client_error "privacy_com_list_cards_raw_auth"
            return 1
        fi
        if [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" != "ok" ]; then
            privacy_card_sweeper_client_error "privacy_com_list_cards_raw_auth"
            return 1
        fi

        pages_scanned=$((pages_scanned + 1))
        total_pages="$(extract_total_pages "$PRIVACY_CLIENT_BODY")"

        local page_summary_json
        page_summary_json="$(privacy_card_sweeper_evaluate_page "$PRIVACY_CLIENT_BODY" "$min_age_seconds" "$sweep_start_epoch" "${PRIVACY_LANE_MEMO_PREFIXES[@]}")"

        local page_counts
        page_counts="$(python3 - "$page_summary_json" <<'PY'
import json
import sys

summary = json.loads(sys.argv[1])
print(f"{summary['total_scanned']}:{summary['skipped_non_lane']}:{summary['skipped_fresh']}")
PY
)"

        local page_total
        local page_non_lane
        local page_fresh
        IFS=':' read -r page_total page_non_lane page_fresh <<< "$page_counts"

        total_scanned=$((total_scanned + page_total))
        skipped_non_lane=$((skipped_non_lane + page_non_lane))
        skipped_fresh=$((skipped_fresh + page_fresh))

        local -a page_candidates=()
        while IFS= read -r page_candidate_token; do
            if [ -n "$page_candidate_token" ]; then
                page_candidates+=("$page_candidate_token")
            fi
        done < <(python3 - "$page_summary_json" <<'PY'
import json
import sys

summary = json.loads(sys.argv[1])
for token in summary.get("candidate_tokens", []):
    print(token)
PY
)
        if [ "${#page_candidates[@]}" -gt 0 ]; then
            candidate_tokens+=("${page_candidates[@]}")
        fi

        current_page=$((current_page + 1))
    done

    if [ "$PRIVACY_SWEEPER_DRY_RUN" = "false" ]; then
        local card_token
        for card_token in "${candidate_tokens[@]-}"; do
            [ -n "$card_token" ] || continue
            if ! privacy_com_close_card "$card_token"; then
                privacy_card_sweeper_client_error "privacy_com_close_card"
                return 1
            fi
            if [ "${PRIVACY_CLIENT_EXIT_CLASS:-}" != "ok" ]; then
                privacy_card_sweeper_client_error "privacy_com_close_card"
                return 1
            fi
            closed_tokens+=("$card_token")
        done
    fi

    local candidate_tokens_json
    local closed_tokens_json
    candidate_tokens_json="$(privacy_card_sweeper_tokens_to_json "${candidate_tokens[@]-}")"
    closed_tokens_json="$(privacy_card_sweeper_tokens_to_json "${closed_tokens[@]-}")"

    privacy_card_sweeper_emit_summary \
        "$PRIVACY_SWEEPER_DRY_RUN" \
        "$pages_scanned" \
        "$total_scanned" \
        "$skipped_non_lane" \
        "$skipped_fresh" \
        "$candidate_tokens_json" \
        "$closed_tokens_json"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    privacy_card_sweeper_main "$@"
fi
