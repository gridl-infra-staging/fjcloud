#!/usr/bin/env bash
# wait_for_pages_parity.sh — Poll served Cloudflare Pages bytes until
# PAGES_ALIAS_URL/_app/version.json reports the target git SHA, then mark
# `ready=true` for the GitHub Actions step output.
# On timeout, mark `ready=false`, emit an error, and exit non-zero so stale
# deployed Pages content fails before browser evidence is trusted.
#
# This script is the single owner of the parity poll. It is invoked
# from .github/workflows/ci.yml::e2e-deployed::"Wait for staging Pages
# deploy parity" and exercised by
# scripts/tests/e2e_deployed_pages_parity_probe_test.sh.
#
# Environment:
#   TARGET_SHA            40-char SHA to wait for. Defaults to $GITHUB_SHA.
#   CLOUDFLARE_GLOBAL_API_KEY
#                         Optional legacy Cloudflare global API key for Pages
#                         detail context in logs.
#   CLOUDFLARE_X_Auth_Email
#                         Optional email paired with the global API key. If
#                         only the legacy CLOUDFLARE_EMAIL alias is set, this
#                         script derives the auth email from it.
#   PAGES_ALIAS_URL       Alias URL whose served version is checked.
#                         Default: https://cloud.staging.flapjack.foo
#   MAX_POLL_ATTEMPTS     Max poll attempts. Default 20.
#   POLL_INTERVAL_SECONDS Sleep between attempts. Default 30.
#   GITHUB_OUTPUT         File path the step output is written to.
#                         Defaults to /dev/null when unset (still emits
#                         stderr diagnostics so local runs stay observable).
#
set -u

TARGET_SHA="${TARGET_SHA:-${GITHUB_SHA:-}}"
PAGES_ALIAS_URL="${PAGES_ALIAS_URL:-https://cloud.staging.flapjack.foo}"
CLOUDFLARE_AUTH_EMAIL="${CLOUDFLARE_X_Auth_Email:-${CLOUDFLARE_EMAIL:-}}"
MAX_POLL_ATTEMPTS="${MAX_POLL_ATTEMPTS:-20}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

write_output() {
    local key="$1" value="$2"
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
}

fail_not_ready() {
    local message="$1"
    echo "::error::wait_for_pages_parity: $message" >&2
    write_output ready false
    exit 1
}

if [[ -z "$TARGET_SHA" ]]; then
    fail_not_ready "TARGET_SHA (or GITHUB_SHA) is empty; cannot poll."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cf_get() {
    local url="$1" out="$2"
    curl -sS --max-time 10 -o "$out" -w '%{http_code}' \
        -H "X-Auth-Email: $CLOUDFLARE_AUTH_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_API_KEY" \
        "$url" 2>/dev/null || true
}

served_get() {
    local url="$1" out="$2"
    curl -sS -L --max-time 10 -o "$out" -w '%{http_code}' \
        "$url" 2>/dev/null || true
}

served_version_from_json() {
    python3 - "$1" <<'PY'
import json
import re
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit

candidates = []
if isinstance(data, dict):
    for key in ("version", "name", "commit", "commit_sha", "commitHash"):
        value = data.get(key)
        if isinstance(value, str):
            candidates.append(value)
elif isinstance(data, str):
    candidates.append(data)

sha = re.compile(r"^[0-9a-f]{40}$")
for candidate in candidates:
    if sha.fullmatch(candidate):
        print(candidate)
        break
else:
    print(candidates[0] if candidates else "")
PY
}

served_version_url() {
    printf '%s/_app/version.json\n' "${PAGES_ALIAS_URL%/}"
}

json_first_account_id() {
    python3 - "$1" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit

for account in data.get("result", []):
    account_id = account.get("id")
    if isinstance(account_id, str) and account_id:
        print(account_id)
        break
else:
    print("")
PY
}

json_project_names() {
    python3 - "$1" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit

for project in data.get("result", []):
    name = project.get("name")
    if isinstance(name, str) and name:
        print(name)
PY
}

alias_deployment_commit() {
    python3 - "$1" "$PAGES_ALIAS_URL" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit

alias_url = sys.argv[2].rstrip("/")
result = data.get("result", {})

for deployment_key in ("canonical_deployment", "latest_deployment"):
    deployment = result.get(deployment_key) or {}
    aliases = deployment.get("aliases") or []
    normalized_aliases = {
        alias.rstrip("/")
        for alias in aliases
        if isinstance(alias, str)
    }
    if alias_url not in normalized_aliases:
        continue
    metadata = ((deployment.get("deployment_trigger") or {}).get("metadata") or {})
    commit_hash = metadata.get("commit_hash") or ""
    if commit_hash:
        print(f"{deployment_key}\t{commit_hash}")
        break
PY
}

resolve_alias_deployment_commit() {
    local accounts_json="$tmp_dir/accounts.json"
    local accounts_http account_id projects_json projects_http project_name detail_json detail_http detail_line

    accounts_http="$(cf_get "https://api.cloudflare.com/client/v4/accounts" "$accounts_json")"
    account_id="$(json_first_account_id "$accounts_json" 2>/dev/null || true)"
    if [[ "$accounts_http" != "200" || -z "$account_id" ]]; then
        echo "cloudflare accounts lookup returned HTTP ${accounts_http:-none} or no account id" >&2
        return 1
    fi

    projects_json="$tmp_dir/projects.json"
    projects_http="$(cf_get "https://api.cloudflare.com/client/v4/accounts/${account_id}/pages/projects" "$projects_json")"
    if [[ "$projects_http" != "200" ]]; then
        echo "cloudflare pages projects lookup returned HTTP ${projects_http:-none}" >&2
        return 1
    fi

    while IFS= read -r project_name; do
        [[ -z "$project_name" ]] && continue
        detail_json="$tmp_dir/project_${project_name//[^A-Za-z0-9_]/_}.json"
        detail_http="$(cf_get "https://api.cloudflare.com/client/v4/accounts/${account_id}/pages/projects/${project_name}" "$detail_json")"
        if [[ "$detail_http" != "200" ]]; then
            echo "cloudflare pages detail for $project_name returned HTTP ${detail_http:-none}" >&2
            continue
        fi

        detail_line="$(alias_deployment_commit "$detail_json" 2>/dev/null || true)"
        if [[ -n "$detail_line" ]]; then
            printf '%s\n' "$detail_line"
            return 0
        fi
    done < <(json_project_names "$projects_json" 2>/dev/null || true)

    return 1
}

metadata_context() {
    local deployment_line deployment_key deployment_commit lookup_stderr

    if [[ -z "${CLOUDFLARE_GLOBAL_API_KEY:-}" || -z "$CLOUDFLARE_AUTH_EMAIL" ]]; then
        echo "cloudflare metadata skipped: auth not configured"
        return 0
    fi

    lookup_stderr="$tmp_dir/lookup_stderr"
    deployment_line="$(resolve_alias_deployment_commit 2>"$lookup_stderr" || true)"
    deployment_key="${deployment_line%%$'\t'*}"
    deployment_commit="${deployment_line#*$'\t'}"
    if [[ "$deployment_key" == "$deployment_commit" ]]; then
        deployment_key=""
        deployment_commit=""
    fi

    if [[ -n "$deployment_commit" ]]; then
        echo "cloudflare metadata ${deployment_key:-unknown} commit $deployment_commit"
        return 0
    fi

    echo "cloudflare metadata none$(cat "$lookup_stderr" 2>/dev/null | sed 's/^/; /')"
}

attempt=1
while [[ "$attempt" -le "$MAX_POLL_ATTEMPTS" ]]; do
    version_json="$tmp_dir/served_version_${attempt}.json"
    version_http="$(served_get "$(served_version_url)" "$version_json")"
    served_version="$(served_version_from_json "$version_json" 2>/dev/null || true)"
    metadata_detail="$(metadata_context)"

    # Served bytes are authoritative: Cloudflare metadata can point at the
    # desired deployment while the alias still serves stale HTML/assets.
    if [[ "$version_http" == "200" && "$served_version" == "$TARGET_SHA" ]]; then
        echo "wait_for_pages_parity: served $PAGES_ALIAS_URL reached $TARGET_SHA via _app/version.json on attempt $attempt/$MAX_POLL_ATTEMPTS; $metadata_detail" >&2
        write_output ready true
        exit 0
    fi

    echo "wait_for_pages_parity: attempt $attempt/$MAX_POLL_ATTEMPTS — served '${served_version:-none}' from $(served_version_url) HTTP ${version_http:-none}, want '$TARGET_SHA'; $metadata_detail" >&2

    if [[ "$attempt" -lt "$MAX_POLL_ATTEMPTS" ]]; then
        sleep "$POLL_INTERVAL_SECONDS"
    fi
    attempt=$((attempt + 1))
done

echo "::error::Pages served content did not reach $TARGET_SHA within budget ($MAX_POLL_ATTEMPTS attempts x ${POLL_INTERVAL_SECONDS}s); stale Pages content cannot be trusted for deployed browser evidence" >&2
write_output ready false
exit 1
