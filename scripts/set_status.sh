#!/usr/bin/env bash
# set_status.sh — update public /status vars in web/wrangler.toml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_WRANGLER_PATH="$REPO_ROOT/web/wrangler.toml"
WRANGLER_PATH="$DEFAULT_WRANGLER_PATH"
STATUS=""
MESSAGE=""
UPDATED=""
PUBLISH=0
PUBLISH_COMMAND=""

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/set_status.sh --status operational|degraded|outage [--message TEXT] [--updated ISO_UTC]
  scripts/set_status.sh --wrangler web/wrangler.toml --status degraded --message "Investigating." --publish

Options:
  --status STATUS          Required. One of: operational, degraded, outage.
  --message TEXT           Optional public status message. Omitted or empty clears it.
  --updated TIMESTAMP      Optional UTC ISO-8601 timestamp. Omitted stamps current UTC time.
  --wrangler PATH          Optional Wrangler config path. Defaults to web/wrangler.toml.
  --publish                After rewriting vars, deploy the web Pages project.
  --publish-command CMD    Test/operator override for --publish handoff.
  --help                   Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

validate_updated_timestamp() {
  local value="$1"
  local normalized
  if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    die "invalid --updated timestamp: $value"
  fi
  normalized="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  if [[ "$normalized" != "$value" ]]; then
    die "invalid --updated timestamp: $value"
  fi
}

toml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --wrangler)
      [[ -n "${2:-}" ]] || die "--wrangler requires a path"
      WRANGLER_PATH="$2"
      shift 2
      ;;
    --status)
      [[ -n "${2:-}" ]] || die "--status requires a value"
      STATUS="$2"
      shift 2
      ;;
    --message)
      [[ $# -ge 2 ]] || die "--message requires a value"
      MESSAGE="$2"
      shift 2
      ;;
    --updated)
      [[ -n "${2:-}" ]] || die "--updated requires a timestamp"
      UPDATED="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --publish-command)
      [[ -n "${2:-}" ]] || die "--publish-command requires an executable name or path"
      PUBLISH_COMMAND="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown arg: $1"
      ;;
  esac
done

case "$STATUS" in
  operational|degraded|outage) ;;
  "") die "--status is required" ;;
  *) die "unknown status: $STATUS" ;;
esac

[[ -f "$WRANGLER_PATH" ]] || die "Wrangler config not found: $WRANGLER_PATH"
WRANGLER_PATH="$(cd "$(dirname "$WRANGLER_PATH")" && pwd)/$(basename "$WRANGLER_PATH")"

if [[ -z "$UPDATED" ]]; then
  UPDATED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
else
  validate_updated_timestamp "$UPDATED"
fi

rewrite_wrangler() {
  local wrangler_path="$1"
  local status_value="$2"
  local updated_value="$3"
  local message_value="$4"
  local tmp_path
  local status_line
  local updated_line
  local message_line

  status_line="SERVICE_STATUS = $(toml_quote "$status_value")"
  updated_line="SERVICE_STATUS_UPDATED = $(toml_quote "$updated_value")"
  message_line="SERVICE_STATUS_MESSAGE = $(toml_quote "$message_value")"

  tmp_path="$(mktemp "${TMPDIR:-/tmp}/fjcloud-set-status.XXXXXX")"
  if ! STATUS_LINE="$status_line" UPDATED_LINE="$updated_line" MESSAGE_LINE="$message_line" awk '
      BEGIN {
        target_count = 3
        targets[1] = "[vars]"
        targets[2] = "[env.production.vars]"
        targets[3] = "[env.preview.vars]"

        key_count = 3
        keys[1] = "SERVICE_STATUS"
        keys[2] = "SERVICE_STATUS_UPDATED"
        keys[3] = "SERVICE_STATUS_MESSAGE"
      }

      function is_target_section(section_name, i) {
        for (i = 1; i <= target_count; i++) {
          if (targets[i] == section_name) {
            return 1
          }
        }
        return 0
      }

      function status_replacement(key) {
        if (key == "SERVICE_STATUS") {
          return ENVIRON["STATUS_LINE"]
        }
        if (key == "SERVICE_STATUS_UPDATED") {
          return ENVIRON["UPDATED_LINE"]
        }
        if (key == "SERVICE_STATUS_MESSAGE") {
          return ENVIRON["MESSAGE_LINE"]
        }
        return ""
      }

      function key_name(line, copy) {
        copy = line
        sub(/^[[:space:]]*/, "", copy)
        sub(/[[:space:]]*=.*/, "", copy)
        return copy
      }

      /^\[[^]]+\]$/ {
        current_section = $0
        if (is_target_section(current_section)) {
          seen_section[current_section] = 1
        }
        print
        next
      }

      {
        if (is_target_section(current_section)) {
          key = key_name($0)
          replacement = status_replacement(key)
          if (replacement != "") {
            seen_key[current_section SUBSEP key] = 1
            print replacement
            next
          }
        }
        print
      }

      END {
        missing = 0
        for (i = 1; i <= target_count; i++) {
          section = targets[i]
          if (!seen_section[section]) {
            print "ERROR: missing required section: " section > "/dev/stderr"
            missing = 1
          }
          for (j = 1; j <= key_count; j++) {
            key = keys[j]
            if (!seen_key[section SUBSEP key]) {
              print "ERROR: missing required key in " section ": " key > "/dev/stderr"
              missing = 1
            }
          }
        }
        if (missing) {
          exit 1
        }
      }
    ' "$wrangler_path" > "$tmp_path"; then
    rm -f "$tmp_path"
    exit 1
  fi

  mv "$tmp_path" "$wrangler_path"
}

run_default_publish() {
  local wrangler_path="$1"
  local branch="${FJCLOUD_STATUS_PUBLISH_BRANCH:-main}"
  local commit_hash
  local default_wrangler_path

  default_wrangler_path="$(cd "$(dirname "$DEFAULT_WRANGLER_PATH")" && pwd)/$(basename "$DEFAULT_WRANGLER_PATH")"
  if [[ "$wrangler_path" != "$default_wrangler_path" ]]; then
    die "default --publish only supports $default_wrangler_path; use --publish-command for custom Wrangler config paths"
  fi

  commit_hash="$(git -C "$REPO_ROOT" rev-parse HEAD)"

  (
    cd "$REPO_ROOT/web"
    npm run build
    npx wrangler pages deploy .svelte-kit/cloudflare \
      --project-name=flapjack-cloud \
      --branch="$branch" \
      --commit-hash="$commit_hash"
  )
}

run_publish() {
  local wrangler_path="$1"

  if [[ -n "$PUBLISH_COMMAND" ]]; then
    command -v "$PUBLISH_COMMAND" >/dev/null 2>&1 || die "publish command not found: $PUBLISH_COMMAND"
    "$PUBLISH_COMMAND" "$wrangler_path"
    return
  fi

  run_default_publish "$wrangler_path"
}

rewrite_wrangler "$WRANGLER_PATH" "$STATUS" "$UPDATED" "$MESSAGE"

if [[ "$PUBLISH" -eq 1 ]]; then
  run_publish "$WRANGLER_PATH"
fi

echo "Updated $WRANGLER_PATH"
