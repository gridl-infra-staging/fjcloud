#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_PATH="$REPO_ROOT/docs/private/secret_distinctness_manifest.md"

usage() {
  cat <<'USAGE'
Usage: scripts/audit_prod_secret_distinctness.sh [--manifest <path>]
USAGE
}

require_option_value() {
  local option_name="$1"
  local option_value="${2-}"
  if [[ -z "$option_value" || "$option_value" == --* ]]; then
    echo "Missing value for $option_name" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      require_option_value "$1" "${2-}"
      MANIFEST_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "manifest_missing|$MANIFEST_PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ROWS_FILE="$TMP_DIR/rows.tsv"

awk -F'|' '
  BEGIN { in_table = 0 }
  /^## Distinctness Contract Table$/ { in_table = 1; next }
  in_table && /^## / { exit }
  in_table {
    if ($0 ~ /^\| ---/) next
    if ($0 ~ /^\| env_var /) next
    if ($0 ~ /^\|/) {
      env = $2
      prod = $3
      stage = $4
      ctype = $5
      pcontract = $6
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", env)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", prod)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", stage)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ctype)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", pcontract)
      gsub(/`/, "", env)
      gsub(/`/, "", prod)
      gsub(/`/, "", stage)
      if (env != "" && prod != "" && stage != "") {
        print env "\t" prod "\t" stage "\t" ctype "\t" pcontract
      }
    }
  }
' "$MANIFEST_PATH" > "$ROWS_FILE"

if [[ ! -s "$ROWS_FILE" ]]; then
  echo "manifest_parse_error|$MANIFEST_PATH" >&2
  exit 1
fi

extract_regex() {
  local contract="$1"
  local which="$2"
  local matches
  matches="$(printf '%s\n' "$contract" | grep -Eo '`\^[^`]+\$`' | tr -d '`' || true)"
  if [[ -z "$matches" ]]; then
    return 0
  fi
  if [[ "$which" == "first" ]]; then
    printf '%s\n' "$matches" | sed -n '1p'
  else
    printf '%s\n' "$matches" | sed -n '2p'
  fi
}

fetch_parameter_value() {
  local key="$1"
  local value
  set +e
  value="$(aws ssm get-parameter --name "$key" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$value" || "$value" == "None" ]]; then
    return 1
  fi
  printf '%s\n' "$value"
}

row_count=0
missing_count=0
identical_count=0
pattern_count=0
parity_count=0

while IFS=$'\t' read -r env_var prod_key staging_key constraint_type pattern_contract; do
  [[ -z "$env_var" ]] && continue
  row_count=$((row_count + 1))

  if [[ "$prod_key" != /fjcloud/prod/* || "$staging_key" != /fjcloud/staging/* ]]; then
    echo "finding|$env_var|$prod_key|parity_error"
    parity_count=$((parity_count + 1))
    continue
  fi

  local_prod_name="${prod_key#/fjcloud/prod/}"
  local_stage_name="${staging_key#/fjcloud/staging/}"
  if [[ "$local_prod_name" != "$local_stage_name" ]]; then
    echo "finding|$env_var|$prod_key|parity_error"
    parity_count=$((parity_count + 1))
    continue
  fi

  prod_value=""
  staging_value=""
  prod_missing=0
  staging_missing=0

  if ! prod_value="$(fetch_parameter_value "$prod_key")"; then
    echo "finding|$env_var|$prod_key|missing"
    missing_count=$((missing_count + 1))
    prod_missing=1
  fi

  if ! staging_value="$(fetch_parameter_value "$staging_key")"; then
    echo "finding|$env_var|$staging_key|missing"
    missing_count=$((missing_count + 1))
    staging_missing=1
  fi

  if [[ $prod_missing -eq 1 || $staging_missing -eq 1 ]]; then
    continue
  fi

  if [[ "$constraint_type" == *must_differ* && "$prod_value" == "$staging_value" ]]; then
    echo "finding|$env_var|$prod_key|identical"
    identical_count=$((identical_count + 1))
  fi

  prod_regex="$(extract_regex "$pattern_contract" first || true)"
  stage_regex="$(extract_regex "$pattern_contract" second || true)"
  if [[ -n "$prod_regex" && -z "$stage_regex" ]]; then
    stage_regex="$prod_regex"
  fi

  if [[ -n "$prod_regex" && ! "$prod_value" =~ $prod_regex ]]; then
    echo "finding|$env_var|$prod_key|pattern_violation"
    pattern_count=$((pattern_count + 1))
  fi

  if [[ -n "$stage_regex" && ! "$staging_value" =~ $stage_regex ]]; then
    echo "finding|$env_var|$staging_key|pattern_violation"
    pattern_count=$((pattern_count + 1))
  fi
done < "$ROWS_FILE"

status="GREEN"
if [[ $missing_count -gt 0 || $identical_count -gt 0 || $pattern_count -gt 0 ]]; then
  status="RED"
elif [[ $parity_count -gt 0 ]]; then
  status="YELLOW"
fi

echo "status|$status|rows=$row_count,missing=$missing_count,identical=$identical_count,pattern=$pattern_count,parity=$parity_count"
[[ "$status" == "GREEN" ]]
