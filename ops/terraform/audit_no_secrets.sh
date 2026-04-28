#!/usr/bin/env bash
# Audit Terraform and GitHub workflow files for secret hygiene.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCAN_ROOT="$REPO_ROOT"

# shellcheck source=../../scripts/lib/secret_audit_parsing.sh
source "$REPO_ROOT/scripts/lib/secret_audit_parsing.sh"

require_option_value() {
  local option_name="$1"
  local option_value="${2-}"

  if [[ -z "$option_value" || "$option_value" == --* ]]; then
    echo "Missing value for $option_name" >&2
    echo "Usage: $0 [--root <repo-root>]" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      require_option_value "$1" "${2-}"
      SCAN_ROOT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--root <repo-root>]" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "Root directory not found: $SCAN_ROOT" >&2
  exit 2
fi

tf_files=()
while IFS= read -r file; do
  tf_files+=("$file")
done < <(rg --files "$SCAN_ROOT" -g '*.tf' -g '!.terraform/**' -g '!.mike/**')

tf_hits=()
if [[ "${#tf_files[@]}" -gt 0 ]]; then
  for tf_file in "${tf_files[@]}"; do
    while IFS= read -r line; do
      tf_hits+=("${tf_file}:${line}")
    done < <(
      strip_tf_comments "$tf_file" | awk '
        BEGIN { IGNORECASE = 1 }
        $0 ~ /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"[^"]+"/ {
          key = $0
          sub(/^[[:space:]]*/, "", key)
          sub(/[[:space:]]*=.*/, "", key)
          key = tolower(key)
          if (key ~ /(^|_)(password|secret|token|api_key|access_key|private_key)($|_)/) {
            print NR ":" $0
          }
        }
      '
    )
  done
fi

workflow_files=()
if [[ -d "$SCAN_ROOT/.github/workflows" ]]; then
  while IFS= read -r wf; do
    workflow_files+=("$wf")
  done < <(rg --files "$SCAN_ROOT/.github/workflows" -g '*.yml' -g '*.yaml')
fi

allowed_secrets=("DEPLOY_IAM_ROLE_ARN" "GITHUB_TOKEN" "GITLEAKS_LICENSE")
workflow_secret_hits=()
if [[ "${#workflow_files[@]}" -gt 0 ]]; then
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue

    secret_name="$(printf '%s\n' "$hit" | sed -nE \
      -e 's#^secrets\.([A-Za-z0-9_]+)$#\1#p' \
      -e 's#^secrets\[[[:space:]]*["'"'"']([A-Za-z0-9_]+)["'"'"'][[:space:]]*\]$#\1#p')"

    if [[ -z "$secret_name" ]]; then
      continue
    fi
    is_allowed=false
    for allowed in "${allowed_secrets[@]}"; do
      if [[ "$secret_name" == "$allowed" ]]; then
        is_allowed=true
        break
      fi
    done
    if [[ "$is_allowed" == false ]]; then
      workflow_secret_hits+=("$hit")
    fi
  done < <(
    for wf in "${workflow_files[@]}"; do
      extract_workflow_secret_refs "$wf"
    done
  )
fi

if [[ "${#tf_hits[@]}" -gt 0 ]]; then
  echo "Hardcoded secret-like Terraform assignments found:"
  printf '  - %s\n' "${tf_hits[@]}"
  echo ""
fi

if [[ "${#workflow_secret_hits[@]}" -gt 0 ]]; then
  echo "Disallowed GitHub Actions secrets found (allowed: ${allowed_secrets[*]}):"
  printf '  - %s\n' "${workflow_secret_hits[@]}"
  echo ""
fi

if [[ "${#tf_hits[@]}" -gt 0 || "${#workflow_secret_hits[@]}" -gt 0 ]]; then
  exit 1
fi

echo "Secret audit passed"
