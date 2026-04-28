#!/usr/bin/env bash
# Shared alert webhook dispatch helper.
#
# Ownership boundary:
# - This helper owns reusable critical-alert payload formatting for Slack/Discord
#   and reusable webhook POST transport behavior.
# - Callers own alert-specific metadata values (title/message/source/nonce/env).

# TODO: Document build_slack_critical_payload.
json_escape_string() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//$'\b'/\\b}
    value=${value//$'\f'/\\f}

    printf '%s' "$value"
}

escape_critical_alert_values() {
    local title="$1"
    local message="$2"
    local source="$3"
    local nonce="$4"
    local environment="$5"

    ESCAPED_ALERT_TITLE="$(json_escape_string "$title")"
    ESCAPED_ALERT_MESSAGE="$(json_escape_string "$message")"
    ESCAPED_ALERT_SOURCE="$(json_escape_string "$source")"
    ESCAPED_ALERT_NONCE="$(json_escape_string "$nonce")"
    ESCAPED_ALERT_ENVIRONMENT="$(json_escape_string "$environment")"
}

build_slack_critical_payload() {
    local title="$1"
    local message="$2"
    local source="$3"
    local nonce="$4"
    local environment="$5"

    escape_critical_alert_values "$title" "$message" "$source" "$nonce" "$environment"

    cat <<EOF
{
  "attachments": [{
    "color": "#d00000",
    "title": "${ESCAPED_ALERT_TITLE}",
    "text": "${ESCAPED_ALERT_MESSAGE}",
    "fields": [
      {"title": "source", "value": "${ESCAPED_ALERT_SOURCE}", "short": true},
      {"title": "nonce", "value": "${ESCAPED_ALERT_NONCE}", "short": true},
      {"title": "Environment", "value": "${ESCAPED_ALERT_ENVIRONMENT}", "short": true}
    ]
  }]
}
EOF
}

build_discord_critical_payload() {
    local title="$1"
    local message="$2"
    local source="$3"
    local nonce="$4"
    local environment="$5"

    escape_critical_alert_values "$title" "$message" "$source" "$nonce" "$environment"

    cat <<EOF
{
  "embeds": [{
    "color": 13631488,
    "title": "${ESCAPED_ALERT_TITLE}",
    "description": "${ESCAPED_ALERT_MESSAGE}",
    "fields": [
      {"name": "source", "value": "${ESCAPED_ALERT_SOURCE}", "inline": true},
      {"name": "nonce", "value": "${ESCAPED_ALERT_NONCE}", "inline": true},
      {"name": "Environment", "value": "${ESCAPED_ALERT_ENVIRONMENT}", "inline": true}
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
}

post_webhook_payload() {
    local url="$1"
    local channel="$2"
    local payload="$3"
    local curl_output http_code curl_status curl_error

    # Webhook URLs carry the destination secret in the path, so fail closed on
    # anything except HTTPS before handing the value to curl.
    if [[ ! "$url" =~ ^https://[^[:space:]]+$ ]]; then
        echo "[FAIL] $channel: webhook URL must use https://" >&2
        return 1
    fi

    curl_output=$(curl -sSL \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 10 \
        "$url" 2>&1) || {
        curl_status=$?
        curl_error="$curl_output"
        if [[ -z "$curl_error" ]]; then
            curl_error="curl exited with status $curl_status"
        fi
        echo "[FAIL] $channel: transport error (curl exit $curl_status): $curl_error" >&2
        return 1
    }

    http_code="$curl_output"

    if [[ "$http_code" =~ ^2 ]]; then
        echo "[OK]   $channel: HTTP $http_code"
        return 0
    fi

    echo "[FAIL] $channel: HTTP $http_code (expected 2xx)" >&2
    return 1
}

send_critical_alert() {
    local channel="$1"
    local webhook_url="$2"
    local title="$3"
    local message="$4"
    local source="$5"
    local nonce="$6"
    local environment="$7"

    local payload
    case "$channel" in
        slack)
            payload="$(build_slack_critical_payload "$title" "$message" "$source" "$nonce" "$environment")"
            ;;
        discord)
            payload="$(build_discord_critical_payload "$title" "$message" "$source" "$nonce" "$environment")"
            ;;
        *)
            echo "[FAIL] $channel: unsupported webhook channel" >&2
            return 1
            ;;
    esac

    post_webhook_payload "$webhook_url" "$channel" "$payload"
}
