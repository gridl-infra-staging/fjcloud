#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_ROOT="$REPO_ROOT/docs/runbooks/evidence"

if [ ! -d "$EVIDENCE_ROOT" ]; then
    echo "ERROR: evidence root not found: docs/runbooks/evidence" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for Playwright evidence structural scan" >&2
    exit 1
fi

finding_count=0

report_finding() {
    local path="$1" class_name="$2"
    printf '%s: %s\n' "$path" "$class_name"
    finding_count=$((finding_count + 1))
}

is_ignored_non_secret_path() {
    local rel_path="$1"
    case "$rel_path" in
        docs/runbooks/evidence/*/stripe_key_fingerprint.txt)
            return 0
            ;;
        docs/runbooks/evidence/announce-gate/*/stripe_latest_event.json)
            return 0
            ;;
        docs/runbooks/evidence/ses-inbox-canary-clean-env/*/customer_loop_events_*.json)
            return 0
            ;;
        docs/runbooks/evidence/ses-inbox-canary-clean-env/*/canary/customer_loop_events_*.json)
            return 0
            ;;
    esac
    return 1
}

has_playwright_web_server_env() {
    local abs_path="$1"
    jq -e '(.config.webServer | type == "object") and (.config.webServer | has("env"))' \
        "$abs_path" >/dev/null 2>&1
}

list_playwright_json_candidates() {
    local path
    for path in \
        "$EVIDENCE_ROOT"/browser-evidence/*/report.json \
        "$EVIDENCE_ROOT"/polished-beta-staging-verify/*/playwright*.json \
        "$EVIDENCE_ROOT"/*/*/rerun_*.json \
        "$EVIDENCE_ROOT"/*/*/*/rerun_*.json
    do
        if [ -f "$path" ]; then
            printf '%s\n' "$path"
        fi
    done

    grep -RIlE '"env"|"webServer"' "$EVIDENCE_ROOT" --include='*.json' 2>/dev/null || true
}

scan_playwright_web_server_env() {
    local abs_path rel_path
    while IFS= read -r abs_path; do
        rel_path="${abs_path#$REPO_ROOT/}"
        if is_ignored_non_secret_path "$rel_path"; then
            continue
        fi
        if ! jq -e . "$abs_path" >/dev/null 2>&1; then
            report_finding "$rel_path" "playwright_json_parse_error"
            continue
        fi
        if has_playwright_web_server_env "$abs_path"; then
            report_finding "$rel_path" "playwright_web_server_env"
        fi
    done < <(list_playwright_json_candidates | sort -u)
}

scan_regex_class() {
    local regex="$1" class_name="$2"
    while IFS= read -r abs_path; do
        rel_path="${abs_path#$REPO_ROOT/}"
        report_finding "$rel_path" "$class_name"
    done < <(grep -RIlE "$regex" "$EVIDENCE_ROOT" 2>/dev/null | sort)
}

scan_playwright_web_server_env
scan_regex_class 'sk_live_[A-Za-z0-9]{16,}' "stripe_live_secret"
scan_regex_class 'AKIA[0-9A-Z]{16}' "aws_access_key_id"
scan_regex_class 'whsec_[A-Za-z0-9]{16,}' "stripe_webhook_secret"

if [ "$finding_count" -gt 0 ]; then
    echo "ERROR: evidence secret hygiene found $finding_count finding(s)" >&2
    exit 1
fi

echo "Evidence secret hygiene passed"
