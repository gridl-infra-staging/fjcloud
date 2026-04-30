#!/usr/bin/env bash
# Shared parsing helpers for Terraform and workflow secret-audit scripts.

# Shared classifier for names that are likely to carry secret values.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
# TODO: Document is_secret_bearing_name.
is_secret_bearing_name() {
  local name="$1"
  local lower
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" =~ (secret|password|passwd|passphrase|private|credential|jwt|webhook|dsn|admin[_]?key|api[_]?key|access[_]?key|signing[_]?key) ]]; then
    return 0
  fi

  if [[ "$lower" =~ (^|_)(database|db|postgres|postgresql|mysql|mariadb|mongo|mongodb|redis|amqp|broker|connection)[_]?url($|_) ]]; then
    return 0
  fi

  if [[ "$lower" =~ (^|_)token($|_) ]] && [[ "$lower" != "token" ]]; then
    return 0
  fi

  return 1
}

# Strip Terraform comments (line + block) while preserving quoted strings.
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

# Extract GitHub workflow secrets.* references, ignoring hash comments.
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
