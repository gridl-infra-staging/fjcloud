#!/usr/bin/env bash
set -euo pipefail

: "${PRIVACY_PRODUCTION_API_KEY:?missing PRIVACY_PRODUCTION_API_KEY}"
PRIVACY_API_KEY="$PRIVACY_PRODUCTION_API_KEY"
BASE_URL="https://api.privacy.com/v1"
BASE_DIR="$1"

dump_probe() {
  local name="$1"
  local method="$2"
  local url="$3"
  local auth_mode="$4"
  local body="${5:-}"
  local headers_tmp body_tmp http_code
  headers_tmp="$(mktemp)"
  body_tmp="$(mktemp)"

  local -a curl_args
  curl_args=(-sS -D "$headers_tmp" -o "$body_tmp" -X "$method" "$url" -H "Accept: application/json")

  if [[ "$auth_mode" == "raw" ]]; then
    curl_args+=( -H "Authorization: ${PRIVACY_API_KEY}" )
  elif [[ "$auth_mode" == "api-key" ]]; then
    curl_args+=( -H "Authorization: api-key ${PRIVACY_API_KEY}" )
  elif [[ "$auth_mode" == "none" ]]; then
    :
  else
    echo "unknown auth mode: $auth_mode" >&2
    exit 1
  fi

  if [[ -n "$body" ]]; then
    curl_args+=( -H "Content-Type: application/json" --data "$body" )
  fi

  http_code="$(curl "${curl_args[@]}" -w '%{http_code}')"

  {
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "method=$method"
    echo "url=$url"
    echo "auth_mode=$auth_mode"
    echo "status_code=$http_code"
  } > "$BASE_DIR/${name}.meta"

  cp "$headers_tmp" "$BASE_DIR/${name}.headers.txt"

  if jq -e . "$body_tmp" >/dev/null 2>&1; then
    jq '
      walk(
        if type == "object" then
          if has("pan") then .pan = "REDACTED_PAN" else . end |
          if has("cvv") then .cvv = "REDACTED_CVV" else . end |
          if has("last_four") then .last_four = "REDACTED_LAST_FOUR" else . end |
          if has("account_name") then .account_name = "REDACTED_ACCOUNT_NAME" else . end
        else . end
      )
    ' "$body_tmp" > "$BASE_DIR/${name}.body.redacted.json"
  else
    cp "$body_tmp" "$BASE_DIR/${name}.body.redacted.txt"
  fi

  rm -f "$headers_tmp" "$body_tmp"
}

cat > "$BASE_DIR/probe_commands.sh" <<'CMDS'
#!/usr/bin/env bash
set -euo pipefail
: "${PRIVACY_API_KEY:?set PRIVACY_API_KEY}"
BASE_URL="https://api.privacy.com/v1"
curl -sS "$BASE_URL/cards?page=1&page_size=2" -H "Authorization: ${PRIVACY_API_KEY}" -H "Accept: application/json"
curl -sS "$BASE_URL/cards?page=1&page_size=2" -H "Authorization: api-key ${PRIVACY_API_KEY}" -H "Accept: application/json"
curl -sS "$BASE_URL/cards?page=1&page_size=2" -H "Accept: application/json"
curl -sS -X POST "$BASE_URL/cards" -H "Authorization: api-key ${PRIVACY_API_KEY}" -H "Content-Type: application/json" -d '{"type":"SINGLE_USE","memo":"stage1-contract-probe","spend_limit":100,"spend_limit_duration":"TRANSACTION","state":"OPEN"}'
curl -sS -X PATCH "$BASE_URL/cards/<CARD_TOKEN>" -H "Authorization: api-key ${PRIVACY_API_KEY}" -H "Content-Type: application/json" -d '{"state":"CLOSED"}'
curl -sS "$BASE_URL/cards/<CARD_TOKEN>" -H "Authorization: api-key ${PRIVACY_API_KEY}" -H "Accept: application/json"
CMDS
chmod 700 "$BASE_DIR/probe_commands.sh"

dump_probe "01_list_cards_auth_raw" "GET" "$BASE_URL/cards?page=1&page_size=2" "raw"
dump_probe "02_list_cards_auth_api_key" "GET" "$BASE_URL/cards?page=1&page_size=2" "api-key"
dump_probe "03_list_cards_missing_auth" "GET" "$BASE_URL/cards?page=1&page_size=2" "none"

CREATE_PAYLOAD='{"type":"SINGLE_USE","memo":"stage1-live-contract-probe","spend_limit":100,"spend_limit_duration":"TRANSACTION","state":"OPEN"}'
dump_probe "04_create_card" "POST" "$BASE_URL/cards" "api-key" "$CREATE_PAYLOAD"

# Extract token from response headers/body artifact before UUID redaction.
CARD_TOKEN="$(jq -r '.token // empty' "$BASE_DIR/04_create_card.body.redacted.json")"
if [[ -z "$CARD_TOKEN" ]]; then
  echo "missing card token in create response" > "$BASE_DIR/05_update_card_closed.meta"
  exit 1
fi

PATCH_PAYLOAD='{"state":"CLOSED"}'
dump_probe "05_update_card_closed" "PATCH" "$BASE_URL/cards/${CARD_TOKEN}" "api-key" "$PATCH_PAYLOAD"
dump_probe "06_get_card_after_close" "GET" "$BASE_URL/cards/${CARD_TOKEN}" "api-key"

for f in "$BASE_DIR"/*.body.redacted.json; do
  jq 'walk(if type=="string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") then "REDACTED_UUID" else . end)' "$f" > "${f}.tmp"
  mv "${f}.tmp" "$f"
done

for f in "$BASE_DIR"/*.headers.txt; do
  sed -i.bak -E 's/^(set-cookie: ).*/\1REDACTED_SESSION_COOKIE/' "$f"
  rm -f "${f}.bak"
done

jq -n \
  --arg list_raw_status "$(awk -F= '/status_code/{print $2}' "$BASE_DIR/01_list_cards_auth_raw.meta")" \
  --arg list_api_status "$(awk -F= '/status_code/{print $2}' "$BASE_DIR/02_list_cards_auth_api_key.meta")" \
  --arg list_noauth_status "$(awk -F= '/status_code/{print $2}' "$BASE_DIR/03_list_cards_missing_auth.meta")" \
  --arg create_status "$(awk -F= '/status_code/{print $2}' "$BASE_DIR/04_create_card.meta")" \
  --arg update_status "$(awk -F= '/status_code/{print $2}' "$BASE_DIR/05_update_card_closed.meta")" \
  --arg final_get_status "$(awk -F= '/status_code/{print $2}' "$BASE_DIR/06_get_card_after_close.meta")" \
  --arg create_state "$(jq -r '.state // empty' "$BASE_DIR/04_create_card.body.redacted.json")" \
  --arg update_state "$(jq -r '.state // empty' "$BASE_DIR/05_update_card_closed.body.redacted.json")" \
  --arg final_state "$(jq -r '.state // empty' "$BASE_DIR/06_get_card_after_close.body.redacted.json")" \
  '{
    list_cards_auth_raw_status: $list_raw_status,
    list_cards_auth_api_key_status: $list_api_status,
    list_cards_missing_auth_status: $list_noauth_status,
    create_card_status: $create_status,
    update_card_status: $update_status,
    get_card_after_close_status: $final_get_status,
    create_state: $create_state,
    update_state: $update_state,
    get_after_close_state: $final_state
  }' > "$BASE_DIR/summary.json"
