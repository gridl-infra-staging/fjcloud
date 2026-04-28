#!/usr/bin/env bash
# Machine-checkable secrets drift audit.
# Emits one structured line per finding:
#   category|name|location|status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/secret_audit_parsing.sh
source "$REPO_ROOT/scripts/lib/secret_audit_parsing.sh"

SCAN_ROOT="$REPO_ROOT"
INVENTORY_PATH=""
INVENTORY_LOCATION="docs/private/secrets_inventory.md"
INVENTORY_OVERRIDE=false
ALLOW_DEFERRED=false

usage() {
    cat <<'USAGE'
Usage: scripts/audit_secrets.sh [--scan-root <path>] [--inventory <path>] [--allow-deferred]
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
      --scan-root)
        require_option_value "$1" "${2-}"
        SCAN_ROOT="$2"
        shift 2
        ;;
      --inventory)
        require_option_value "$1" "${2-}"
        INVENTORY_PATH="$2"
        INVENTORY_LOCATION="$(basename "$2")"
        INVENTORY_OVERRIDE=true
        shift 2
        ;;
      --allow-deferred)
        ALLOW_DEFERRED=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$INVENTORY_OVERRIDE" == false ]]; then
  INVENTORY_PATH="$SCAN_ROOT/docs/private/secrets_inventory.md"
fi

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "scan_root_missing|scan_root|$SCAN_ROOT|scan_root_missing"
  exit 1
fi

if [[ ! -f "$INVENTORY_PATH" ]]; then
  if [[ "$INVENTORY_OVERRIDE" == false ]]; then
    echo "inventory_missing|inventory|docs/private/secrets_inventory.md|inventory_missing"
  else
    echo "inventory_missing|inventory|$INVENTORY_LOCATION|inventory_missing"
  fi
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OBSERVED_RAW="$TMP_DIR/observed_raw.txt"
OBSERVED="$TMP_DIR/observed.txt"
INVENTORY_RAW="$TMP_DIR/inventory_raw.txt"
INVENTORY="$TMP_DIR/inventory.txt"
FINDINGS="$TMP_DIR/findings.txt"
DEFERRED_RAW="$TMP_DIR/deferred_raw.txt"
DEFERRED="$TMP_DIR/deferred.txt"
UNRESOLVED="$TMP_DIR/unresolved_findings.txt"

: > "$OBSERVED_RAW"
: > "$INVENTORY_RAW"
: > "$FINDINGS"
: > "$DEFERRED_RAW"

resolve_scope_path() {
  local rel="$1"
  local abs="$SCAN_ROOT/$rel"
  if [[ -d "$abs" ]]; then
    printf '%s\n' "$abs"
  fi
}

record_observed_var() {
  local name="$1"
  local rel="$2"
  local line_no="$3"

  if is_secret_bearing_name "$name"; then
    printf '%s|%s:%s\n' "$name" "$rel" "$line_no" >> "$OBSERVED_RAW"
  fi
}

record_shell_refs_from_line() {
  local line="$1"
  local rel="$2"
  local line_no="$3"
  local scan_line var_name

  scan_line="$line"
  while [[ "$scan_line" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    var_name="${BASH_REMATCH[1]}"
    record_observed_var "$var_name" "$rel" "$line_no"
    scan_line="${scan_line#*\$\{$var_name\}}"
  done

  while [[ "$scan_line" =~ (^|[^\\])\$([A-Za-z_][A-Za-z0-9_]*) ]]; do
    var_name="${BASH_REMATCH[2]}"
    record_observed_var "$var_name" "$rel" "$line_no"
    scan_line="${scan_line#*"$var_name"}"
  done
}

scan_shell_file() {
  local file="$1"
  local rel="$2"
  local line line_no=0 parse_status

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))

    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*= ]]; then
      parse_env_assignment_line "$line" 2>/dev/null && parse_status=0 || parse_status=$?
      if [[ "$parse_status" -eq 0 ]]; then
        record_shell_refs_from_line "$ENV_ASSIGNMENT_VALUE" "$rel" "$line_no"
      fi
    fi

    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    record_shell_refs_from_line "$line" "$rel" "$line_no"
  done < "$file"
}

scan_workflow_file() {
  local file="$1"
  local rel="$2"
  local ref secret_name line_no

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    secret_name="$(printf '%s\n' "$ref" | sed -nE \
      -e 's#^secrets\.([A-Za-z0-9_]+)$#\1#p' \
      -e 's#^secrets\[[[:space:]]*["'"'"']([A-Za-z0-9_]+)["'"'"'][[:space:]]*\]$#\1#p')"
    [[ -z "$secret_name" ]] && continue

    line_no="$(rg -n -m1 --fixed-strings "$ref" "$file" | cut -d: -f1 || true)"
    [[ -z "$line_no" ]] && line_no=1
    record_observed_var "$secret_name" "$rel" "$line_no"
  done < <(extract_workflow_secret_refs "$file")
}

scan_c_like_file() {
  local file="$1"
  local rel="$2"
  local candidate_name line_no
  while IFS='|' read -r candidate_name line_no; do
    [[ -z "$candidate_name" ]] && continue
    record_observed_var "$candidate_name" "$rel" "$line_no"
  done < <(awk '
    BEGIN { in_block = 0 }
    {
      line = $0
      out = ""
      in_double = 0
      escaped = 0
      i = 1

      while (i <= length(line)) {
        ch = substr(line, i, 1)
        next_ch = (i < length(line)) ? substr(line, i + 1, 1) : ""

        if (in_block) {
          if (ch == "*" && next_ch == "/") {
            in_block = 0
            i += 2
            continue
          }
          i++
          continue
        }

        if (in_double) {
          out = out ch
          if (escaped) {
            escaped = 0
          } else if (ch == "\\") {
            escaped = 1
          } else if (ch == "\"") {
            in_double = 0
          }
          i++
          continue
        }

        if (ch == "\"") {
          in_double = 1
          out = out ch
          i++
          continue
        }

        if (ch == "/" && next_ch == "*") {
          in_block = 1
          i += 2
          continue
        }

        if (ch == "/" && next_ch == "/") {
          break
        }

        out = out ch
        i++
      }

      while (match(out, /std::env::var\("[A-Za-z_][A-Za-z0-9_]*"\)/)) {
        match_text = substr(out, RSTART, RLENGTH)
        gsub(/^std::env::var\("|"\)$/, "", match_text)
        printf "%s|%d\n", match_text, NR
        out = substr(out, RSTART + RLENGTH)
      }

      while (match(out, /import\.meta\.env\.[A-Za-z_][A-Za-z0-9_]*/)) {
        match_text = substr(out, RSTART, RLENGTH)
        sub(/^import\.meta\.env\./, "", match_text)
        printf "%s|%d\n", match_text, NR
        out = substr(out, RSTART + RLENGTH)
      }
    }
  ' "$file")
}

scan_terraform_file() {
  local file="$1"
  local rel="$2"
  local line line_no var_name

  while IFS= read -r line; do
    while [[ "$line" =~ var\.([A-Za-z_][A-Za-z0-9_]*) ]]; do
      var_name="${BASH_REMATCH[1]}"
      line_no="$(rg -n -m1 --fixed-strings "$line" "$file" | cut -d: -f1 || true)"
      [[ -z "$line_no" ]] && line_no=1
      record_observed_var "$var_name" "$rel" "$line_no"
      line="${line#*var.$var_name}"
    done
  done < <(strip_tf_comments "$file")
}

parse_inventory() {
    local line line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_no=$((line_no + 1))
      if [[ "$line" =~ \|[[:space:]]*\`([A-Za-z_][A-Za-z0-9_]*)\`[[:space:]]*\| ]]; then
        local secret_name="${BASH_REMATCH[1]}"
        printf '%s|%s:%s\n' "$secret_name" "$INVENTORY_LOCATION" "$line_no" >> "$INVENTORY_RAW"

        if [[ "$line" =~ deferred_to_wave2a:([^[:space:]|]+) ]]; then
          printf '%s|%s|%s:%s\n' \
            "$secret_name" \
            "${BASH_REMATCH[1]}" \
            "$INVENTORY_LOCATION" \
            "$line_no" >> "$DEFERRED_RAW"
        fi
      fi
    done < "$INVENTORY_PATH"
}

deferred_gap_path_is_valid() {
    local deferred_path="$1"

    [[ "$deferred_path" == docs/gaps/*.md ]] || return 1
    [[ "$deferred_path" != /* ]] || return 1
    [[ "$deferred_path" != *".."* ]] || return 1
}

filter_deferred_findings() {
    local finding category name location status deferred_path

    if [[ "$ALLOW_DEFERRED" != true ]]; then
        cat "$FINDINGS"
        return
    fi

    while IFS='|' read -r category name location status; do
        [[ -z "$category" ]] && continue

        deferred_path="$(awk -F'|' -v finding_name="$name" '
            $1 == finding_name { print $2; exit }
        ' "$DEFERRED" 2>/dev/null || true)"

        if [[ "$category" == "inventory" \
            && "$status" == "drift_orphan_inventory_row" \
            && -n "$deferred_path" ]] \
            && deferred_gap_path_is_valid "$deferred_path" \
            && [[ -f "$SCAN_ROOT/$deferred_path" ]]; then
            continue
        fi

        printf '%s|%s|%s|%s\n' "$category" "$name" "$location" "$status"
    done < "$FINDINGS"
}

scan_scope() {
  local dir rel file

  dir="$(resolve_scope_path scripts || true)"
  if [[ -n "$dir" ]]; then
    while IFS= read -r file; do
      rel="${file#"$SCAN_ROOT"/}"
      scan_shell_file "$file" "$rel"
    done < <(rg --files "$dir" -g '*.sh')
  fi

  dir="$(resolve_scope_path .github/workflows || true)"
  if [[ -n "$dir" ]]; then
    while IFS= read -r file; do
      rel="${file#"$SCAN_ROOT"/}"
      scan_workflow_file "$file" "$rel"
    done < <(rg --files "$dir" -g '*.yml' -g '*.yaml')
  fi

  dir="$(resolve_scope_path infra || true)"
  if [[ -n "$dir" ]]; then
    while IFS= read -r file; do
      rel="${file#"$SCAN_ROOT"/}"
      scan_c_like_file "$file" "$rel"
    done < <(rg --files "$dir" -g '*.rs')
  fi

  dir="$(resolve_scope_path web/src || true)"
  if [[ -n "$dir" ]]; then
    while IFS= read -r file; do
      rel="${file#"$SCAN_ROOT"/}"
      scan_c_like_file "$file" "$rel"
    done < <(rg --files "$dir" -g '*.ts' -g '*.tsx' -g '*.js' -g '*.jsx' -g '*.svelte')
  fi

  dir="$(resolve_scope_path ops/terraform || true)"
  if [[ -n "$dir" ]]; then
    while IFS= read -r file; do
      rel="${file#"$SCAN_ROOT"/}"
      scan_terraform_file "$file" "$rel"
    done < <(rg --files "$dir" -g '*.tf' -g '!.terraform/**')
  fi
}

parse_inventory
scan_scope

sort -t'|' -k1,1 -k2,2 "$OBSERVED_RAW" | awk -F'|' '!seen[$1]++' > "$OBSERVED"
sort -t'|' -k1,1 -k2,2 "$INVENTORY_RAW" | awk -F'|' '!seen[$1]++' > "$INVENTORY"
sort -t'|' -k1,1 -k2,2 "$DEFERRED_RAW" | awk -F'|' '!seen[$1]++' > "$DEFERRED"

awk -F'|' '
  FILENAME == ARGV[1] { inv[$1] = 1; next }
  { if (!($1 in inv)) print "consumer|" $1 "|" $2 "|drift_unlisted_consumer" }
' "$INVENTORY" "$OBSERVED" >> "$FINDINGS"

awk -F'|' '
  FILENAME == ARGV[1] { obs[$1] = 1; next }
  { if (!($1 in obs)) print "inventory|" $1 "|" $2 "|drift_orphan_inventory_row" }
' "$OBSERVED" "$INVENTORY" >> "$FINDINGS"

if [[ -s "$FINDINGS" ]]; then
    filter_deferred_findings | sort -u > "$UNRESOLVED"

    if [[ -s "$UNRESOLVED" ]]; then
        cat "$UNRESOLVED"
        exit 1
    fi
fi

exit 0
