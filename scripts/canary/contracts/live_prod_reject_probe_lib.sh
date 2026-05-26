#!/usr/bin/env bash
# Shared helper for live prod reject-contract probes.

live_prod_response_path() {
  local artifact_stem="$1"
  if [[ -n "${EVDIR:-}" ]]; then
    mkdir -p "$EVDIR"
    printf "%s\n" "$EVDIR/live_prod_${artifact_stem}.response"
    return 0
  fi

  mktemp "/tmp/live_prod_${artifact_stem}_XXXXXX"
}

capture_live_prod_response() {
  local output_path="$1"
  local output_dir
  local output_name
  local temp_path
  shift

  output_dir="$(dirname -- "$output_path")"
  output_name="$(basename -- "$output_path")"

  mkdir -p "$output_dir"
  temp_path="$(mktemp "${output_dir}/${output_name}.tmp.XXXXXX")"

  # Refuse to replace non-files so a crafted artifact path cannot redirect output.
  if [[ -e "$output_path" && ! -f "$output_path" ]]; then
    rm -f "$temp_path"
    printf 'FAIL: refusing to overwrite non-regular path %s\n' "$output_path" >&2
    return 1
  fi
  
  if ! curl -isS --max-time 30 "$@" > "$temp_path"; then
    rm -f "$temp_path"
    return 1
  fi
  chmod 600 "$temp_path"
  if ! mv -f "$temp_path" "$output_path"; then
    rm -f "$temp_path"
    return 1
  fi
  printf "response_file=%s\n" "$output_path"
}

assert_status_code() {
  local expected_status="$1"
  local response_path="$2"

  if grep -Eq "^HTTP/[0-9.]+ ${expected_status}( |$)" "$response_path"; then
    printf "PASS: observed HTTP %s\n" "$expected_status"
    return 0
  fi

  printf "FAIL: expected HTTP %s in %s\n" "$expected_status" "$response_path" >&2
  head -n 1 "$response_path" >&2 || true
  return 1
}
