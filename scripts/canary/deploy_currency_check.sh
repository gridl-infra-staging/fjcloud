#!/usr/bin/env bash
# Detect deployed mirror commits that have fallen too far behind mirror main.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ALERT_DISPATCH_HELPER="${ALERT_DISPATCH_HELPER:-$REPO_ROOT/scripts/lib/alert_dispatch.sh}"
# shellcheck source=../lib/alert_dispatch.sh
source "$ALERT_DISPATCH_HELPER"

DEFAULT_ENV_MATRIX=$'prod|https://api.flapjack.foo/version|gridl-infra-prod/fjcloud\nstaging|https://api.staging.flapjack.foo/version|gridl-infra-staging/fjcloud'
DEPLOY_CURRENCY_ENV_MATRIX="${DEPLOY_CURRENCY_ENV_MATRIX:-$DEFAULT_ENV_MATRIX}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
DRIFT_MAX_AGE_HOURS="${DRIFT_MAX_AGE_HOURS:-24}"
DEPLOY_CURRENCY_NOW_EPOCH="${DEPLOY_CURRENCY_NOW_EPOCH:-$(date -u +%s)}"
DEPLOY_CURRENCY_NOW_ISO="${DEPLOY_CURRENCY_NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

json_value() {
    local path="$1"
    local field="$2"
    python3 - "$path" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

value = data
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(1)
    value = value[part]

if value is None or value == "":
    sys.exit(1)
print(value)
PY
}

oldest_compare_commit_epoch() {
    local path="$1"
    python3 - "$path" <<'PY'
import json
import sys
from datetime import datetime, timezone

def parse_epoch(value):
    if not isinstance(value, str) or not value:
        raise ValueError("missing date")
    normalized = value.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    epochs = [
        parse_epoch(commit["commit"]["committer"]["date"])
        for commit in data.get("commits", [])
    ]
except Exception:
    sys.exit(1)

if not epochs:
    sys.exit(1)
print(min(epochs))
PY
}

short_sha() {
    local sha="$1"
    printf '%s' "${sha:0:12}"
}

github_api_base_allows_auth() {
    case "${GITHUB_API_BASE%/}" in
        https://api.github.com) return 0 ;;
        *) return 1 ;;
    esac
}

probe_version_mirror_sha() {
    local url="$1"
    local body_path="$2"

    curl -fsS --max-time 10 "$url" > "$body_path" 2>/dev/null || return 1
    json_value "$body_path" "mirror_sha" >/dev/null || return 1
}

github_http_get() {
    local url="$1"
    local body_path="$2"
    local endpoint_kind="$3"
    local attempt http_code curl_rc err_path

    err_path="$(mktemp)"
    for attempt in 1 2; do
        curl_rc=0
        if [ -n "$GITHUB_TOKEN" ] && github_api_base_allows_auth; then
            http_code="$(curl -sS -L \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer $GITHUB_TOKEN" \
                --max-time 10 \
                -o "$body_path" \
                -w '%{http_code}' \
                "$url" 2>"$err_path")" || curl_rc=$?
        else
            http_code="$(curl -sS -L \
                -H "Accept: application/vnd.github+json" \
                --max-time 10 \
                -o "$body_path" \
                -w '%{http_code}' \
                "$url" 2>"$err_path")" || curl_rc=$?
        fi

        if [ "$curl_rc" -eq 0 ] && [[ "$http_code" =~ ^2 ]]; then
            rm -f "$err_path"
            return 0
        fi

        if [ "$endpoint_kind" = "compare" ] && [ "$curl_rc" -eq 0 ] && [ "$http_code" = "404" ]; then
            rm -f "$err_path"
            return 44
        fi

        if [ "$attempt" -eq 2 ]; then
            echo "GitHub API probe failed: $url (curl=$curl_rc http=${http_code:-unknown})" >&2
            if [ -s "$err_path" ]; then
                sed 's/^/GitHub curl stderr: /' "$err_path" >&2
            fi
            rm -f "$err_path"
            return 1
        fi
    done
}

send_breach_alert() {
    local label="$1"
    local title="$2"
    local message="$3"

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        echo "ALERT DELIVERY UNCONFIGURED: $label: $title" >&2
        return 1
    fi

    send_critical_alert \
        "discord" \
        "$DISCORD_WEBHOOK_URL" \
        "$title" \
        "$message" \
        "deploy_currency_check" \
        "deploy-currency-${label}-${DEPLOY_CURRENCY_NOW_EPOCH}" \
        "$label"
}

record_breach() {
    local label="$1"
    local message="$2"
    local delivery_failed_var="$3"

    if ! send_breach_alert "$label" "Deploy currency drift breach" "$message"; then
        printf -v "$delivery_failed_var" '%s' "1"
    fi
}

evaluate_environment() {
    local label="$1"
    local version_url="$2"
    local mirror_repo="$3"

    local version_body head_body compare_body
    local deployed_sha mirror_head_sha ahead_by oldest_epoch age_seconds age_hours threshold_seconds
    local any_breach_var="$4"
    local delivery_failed_var="$5"

    version_body="$(mktemp)"
    head_body="$(mktemp)"
    compare_body="$(mktemp)"

    if ! probe_version_mirror_sha "$version_url" "$version_body"; then
        record_breach \
            "$label" \
            "$label /version probe failed for $version_url; deployed mirror_sha is unknown." \
            "$delivery_failed_var"
        printf 'env=%s status=breach reason=version_probe_failed deployed=unknown mirror_head=unknown\n' "$label"
        printf -v "$any_breach_var" '%s' "1"
        rm -f "$version_body" "$head_body" "$compare_body"
        return 0
    fi

    deployed_sha="$(json_value "$version_body" "mirror_sha")"

    local head_url="${GITHUB_API_BASE%/}/repos/${mirror_repo}/commits/main"
    local head_rc=0
    github_http_get "$head_url" "$head_body" "commits_main" || head_rc=$?
    if [ "$head_rc" -ne 0 ] || ! mirror_head_sha="$(json_value "$head_body" "sha")"; then
        record_breach \
            "$label" \
            "$label GitHub API probe failed for $mirror_repo commits/main; deployed mirror_sha=$deployed_sha." \
            "$delivery_failed_var"
        printf 'env=%s status=breach reason=github_probe_failed deployed=%s mirror_head=unknown\n' "$label" "$(short_sha "$deployed_sha")"
        printf -v "$any_breach_var" '%s' "1"
        rm -f "$version_body" "$head_body" "$compare_body"
        return 0
    fi

    local compare_url="${GITHUB_API_BASE%/}/repos/${mirror_repo}/compare/${deployed_sha}...main"
    local compare_rc=0
    github_http_get "$compare_url" "$compare_body" "compare" || compare_rc=$?
    if [ "$compare_rc" -eq 44 ]; then
        record_breach \
            "$label" \
            "$label mirror compare found unresolvable deployed sha; deployed mirror_sha=$deployed_sha mirror_head=$mirror_head_sha." \
            "$delivery_failed_var"
        printf 'env=%s status=breach reason=unresolvable_deployed_sha deployed=%s mirror_head=%s\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")"
        printf -v "$any_breach_var" '%s' "1"
        rm -f "$version_body" "$head_body" "$compare_body"
        return 0
    fi
    if [ "$compare_rc" -ne 0 ]; then
        record_breach \
            "$label" \
            "$label GitHub API probe failed for $mirror_repo compare; deployed mirror_sha=$deployed_sha mirror_head=$mirror_head_sha." \
            "$delivery_failed_var"
        printf 'env=%s status=breach reason=github_probe_failed deployed=%s mirror_head=%s\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")"
        printf -v "$any_breach_var" '%s' "1"
        rm -f "$version_body" "$head_body" "$compare_body"
        return 0
    fi

    if ! ahead_by="$(json_value "$compare_body" "ahead_by")"; then
        record_breach \
            "$label" \
            "$label GitHub API probe failed: compare response missing ahead_by; deployed mirror_sha=$deployed_sha mirror_head=$mirror_head_sha." \
            "$delivery_failed_var"
        printf 'env=%s status=breach reason=github_probe_failed deployed=%s mirror_head=%s\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")"
        printf -v "$any_breach_var" '%s' "1"
        rm -f "$version_body" "$head_body" "$compare_body"
        return 0
    fi

    if [ "$ahead_by" -gt 0 ]; then
        if ! oldest_epoch="$(oldest_compare_commit_epoch "$compare_body")"; then
            record_breach \
                "$label" \
                "$label GitHub API probe failed: compare response missing oldest undelivered commit date; deployed mirror_sha=$deployed_sha mirror_head=$mirror_head_sha ahead_by=$ahead_by." \
                "$delivery_failed_var"
            printf 'env=%s status=breach reason=github_probe_failed deployed=%s mirror_head=%s ahead_by=%s\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")" "$ahead_by"
            printf -v "$any_breach_var" '%s' "1"
            rm -f "$version_body" "$head_body" "$compare_body"
            return 0
        fi

        age_seconds=$((DEPLOY_CURRENCY_NOW_EPOCH - oldest_epoch))
        if [ "$age_seconds" -lt 0 ]; then
            age_seconds=0
        fi
        age_hours=$((age_seconds / 3600))
        threshold_seconds=$((DRIFT_MAX_AGE_HOURS * 3600))

        # Use oldest-undelivered age: HEAD-age shortcuts miss continuous-push
        # dead-pipeline drift, while deployed-age shortcuts false-page after
        # quiet periods or in-flight deploys.
        if [ "$age_seconds" -gt "$threshold_seconds" ]; then
            record_breach \
                "$label" \
                "$label oldest undelivered mirror commit is ${age_hours}h old at $DEPLOY_CURRENCY_NOW_ISO; deployed mirror_sha=$deployed_sha mirror_head=$mirror_head_sha ahead_by=$ahead_by threshold=${DRIFT_MAX_AGE_HOURS}h." \
                "$delivery_failed_var"
            printf 'env=%s status=breach reason=oldest_undelivered_too_old deployed=%s mirror_head=%s ahead_by=%s oldest_undelivered_age=%sh\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")" "$ahead_by" "$age_hours"
            printf -v "$any_breach_var" '%s' "1"
            rm -f "$version_body" "$head_body" "$compare_body"
            return 0
        fi

        printf 'env=%s status=current deployed=%s mirror_head=%s ahead_by=%s oldest_undelivered_age=%sh\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")" "$ahead_by" "$age_hours"
    else
        printf 'env=%s status=current deployed=%s mirror_head=%s ahead_by=0\n' "$label" "$(short_sha "$deployed_sha")" "$(short_sha "$mirror_head_sha")"
    fi

    rm -f "$version_body" "$head_body" "$compare_body"
}

main() {
    local any_breach=0
    local delivery_failed=0
    local entry label version_url mirror_repo

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        label="${entry%%|*}"
        version_url="${entry#*|}"
        version_url="${version_url%%|*}"
        mirror_repo="${entry##*|}"
        evaluate_environment "$label" "$version_url" "$mirror_repo" any_breach delivery_failed
    done <<EOF_MATRIX
$DEPLOY_CURRENCY_ENV_MATRIX
EOF_MATRIX

    if [ "$any_breach" -ne 0 ] || [ "$delivery_failed" -ne 0 ]; then
        return 1
    fi
}

main "$@"
