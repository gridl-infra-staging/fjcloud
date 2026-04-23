#!/usr/bin/env bash
# Audit Terraform and GitHub workflow files for secret hygiene.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--root <repo-root>]" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Root directory not found: $ROOT_DIR" >&2
  exit 2
fi

strip_tf_comments() {
  local file="$1"
  awk '
    BEGIN { in_block_comment = 0 }
    {
      line = $0
      out = ""
      in_string = 0
      escaped = 0
      i = 1
      while (i <= length(line)) {
        ch = substr(line, i, 1)
        next_ch = (i < length(line)) ? substr(line, i + 1, 1) : ""

        if (in_block_comment) {
          if (ch == "*" && next_ch == "/") {
            in_block_comment = 0
            i += 2
            continue
          }
          i++
          continue
        }

        if (in_string) {
          out = out ch
          if (escaped) {
            escaped = 0
          } else if (ch == "\\") {
            escaped = 1
          } else if (ch == "\"") {
            in_string = 0
          }
          i++
          continue
        }

        if (ch == "\"") {
          in_string = 1
          out = out ch
          i++
          continue
        }

        if (ch == "#" || (ch == "/" && next_ch == "/")) {
          break
        }

        if (ch == "/" && next_ch == "*") {
          in_block_comment = 1
          i += 2
          continue
        }

        out = out ch
        i++
      }

      gsub(/^[[:space:]]+|[[:space:]]+$/, "", out)
      if (out ~ /^[[:space:]]*$/) { next }
      print out
    }
  ' "$file"
}

extract_workflow_secret_refs() {
  local file="$1"
  awk '
    function emit_secret_hits(text,   rest, hit) {
      rest = text
      while (match(rest, /secrets\.[A-Za-z0-9_]+|secrets\[[[:space:]]*'\''[A-Za-z0-9_]+'\''[[:space:]]*\]|secrets\[[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*\]/)) {
        hit = substr(rest, RSTART, RLENGTH)
        print hit
        rest = substr(rest, RSTART + RLENGTH)
      }
    }

    {
      line = $0
      out = ""
      in_single = 0
      in_double = 0
      escaped = 0

      for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)

        if (in_double) {
          out = out ch
          if (escaped) {
            escaped = 0
          } else if (ch == "\\") {
            escaped = 1
          } else if (ch == "\"") {
            in_double = 0
          }
          continue
        }

        if (in_single) {
          out = out ch
          if (ch == "'\''") {
            in_single = 0
          }
          continue
        }

        if (ch == "\"") {
          in_double = 1
          out = out ch
          continue
        }

        if (ch == "'\''") {
          in_single = 1
          out = out ch
          continue
        }

        if (ch == "#") {
          break
        }

        out = out ch
      }

      emit_secret_hits(out)
    }
  ' "$file"
}

tf_files=()
while IFS= read -r file; do
  tf_files+=("$file")
done < <(rg --files "$ROOT_DIR" -g '*.tf' -g '!.terraform/**' -g '!.mike/**')

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
if [[ -d "$ROOT_DIR/.github/workflows" ]]; then
  while IFS= read -r wf; do
    workflow_files+=("$wf")
  done < <(rg --files "$ROOT_DIR/.github/workflows" -g '*.yml' -g '*.yaml')
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
