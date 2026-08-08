#!/usr/bin/env bash
# Schedule-bound contract for the mirror manifest matrix job.
# Caller provides REPO_ROOT plus job_block, pass, and fail.

assert_mirror_shard_timeout_covers_schedule_bound() {
  local runner="$REPO_ROOT/scripts/run_mirror_manifest_shard.sh"
  local serial_registry="$REPO_ROOT/scripts/tests/serial_only_tests.txt"
  local block job_minutes concurrency suite_timeout matrix_shards shard_count serial_paths
  local shard listed test_path serial_count non_serial_count waves shard_seconds
  local max_seconds=0 max_shard=0

  block="$(job_block "mirror-manifest-shards")"
  job_minutes="$(printf '%s\n' "$block" | awk '/^    timeout-minutes: [0-9]+$/ { print $2 }')"
  concurrency="$(awk -F= '$1 == "MAX_CONCURRENT_SUITES" { print $2 }' "$runner")"
  suite_timeout="$(awk -F= '$1 == "SUITE_TIMEOUT_SECONDS" { print $2 }' "$runner")"
  matrix_shards="$(printf '%s\n' "$block" | awk '/^        shard: \[[0-9, ]+\]$/ {
    sub(/^.*\[/, ""); sub(/\].*$/, ""); gsub(/,/, " "); print
  }')"
  shard_count="$(awk '{ print NF }' <<<"$matrix_shards")"
  serial_paths="$(awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) print }' "$serial_registry")"

  if [[ ! "$job_minutes" =~ ^[1-9][0-9]*$ || ! "$concurrency" =~ ^[1-9][0-9]*$ ||
        ! "$suite_timeout" =~ ^[1-9][0-9]*$ || ! "$shard_count" =~ ^[1-9][0-9]*$ ]]; then
    fail "mirror-manifest-shards timeout covers its live runner schedule (could not parse schedule inputs)"
    return
  fi

  for shard in $matrix_shards; do
    if ! listed="$(bash "$runner" --list --shard "$shard" --shards "$shard_count")"; then
      fail "mirror-manifest-shards timeout covers its live runner schedule (shard $shard listing failed)"
      return
    fi
    serial_count=0
    non_serial_count=0
    while IFS= read -r test_path; do
      [[ -n "$test_path" ]] || continue
      if grep -Fqx -- "$test_path" <<<"$serial_paths"; then
        serial_count=$((serial_count + 1))
      else
        non_serial_count=$((non_serial_count + 1))
      fi
    done <<<"$listed"
    waves=$(((non_serial_count + concurrency - 1) / concurrency))
    shard_seconds=$(((waves + serial_count) * suite_timeout))
    if (( shard_seconds > max_seconds )); then
      max_seconds="$shard_seconds"
      max_shard="$shard"
    fi
  done

  if (( job_minutes * 60 > max_seconds )); then
    pass "mirror-manifest-shards timeout covers its live runner schedule (job $((job_minutes * 60))s > shard $max_shard bound ${max_seconds}s)"
  else
    fail "mirror-manifest-shards timeout covers its live runner schedule (job $((job_minutes * 60))s <= shard $max_shard bound ${max_seconds}s)"
  fi
}
