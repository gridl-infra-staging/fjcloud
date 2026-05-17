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
