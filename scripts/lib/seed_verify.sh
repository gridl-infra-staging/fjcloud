#!/usr/bin/env bash
# seed_verify.sh — Membership-check helpers for the local-dev seed.
#
# Sourced by scripts/seed_local.sh (and by scripts/tests/seed_local_test.sh
# to exercise the verify path in isolation against realistic-volume fixtures).
#
# Callers must have already defined: `log`, `die`, `api_call_with_token`,
# and SEED_INDEX_TARGETS (array of "user_key|index_name|region" rows).

# Verifies that each seed target index (for the given user_key) is present in
# the user's GET /indexes response. Dies if any target is missing.
#
# IMPORTANT — do NOT replace the inner Python with `printf | grep -Fxq`.
# That idiom is broken under `set -o pipefail` with large responses: when
# `grep -q` finds the match and closes stdin, the upstream `printf` gets
# SIGPIPE → exit 141, pipefail propagates the 141 as pipeline failure, and
# `if !` mis-reports the index as missing. Reproduced reliably at ~4000+
# index entries on dev machines that accumulated e2e fixtures over weeks.
# Anchored 2026-05-31; regression tests:
#   scripts/tests/seed_local_test.sh
#     ::test_verify_seeded_indexes_handles_realistic_index_volume
#     ::test_seed_local_does_not_contain_sigpipe_grep_idiom
#
# Python's `json.load(sys.stdin)` drains stdin to EOF before deciding, so
# the upstream `printf` is never killed mid-write. Safe under pipefail.
# TODO: Document verify_seeded_indexes_for_user.
# TODO: Document verify_seeded_indexes_for_user.
# TODO: Document verify_seeded_indexes_for_user.
# TODO: Document verify_seeded_indexes_for_user.
# TODO: Document verify_seeded_indexes_for_user.
# Fetch the user's indexes once and verify every configured seed target by exact name.
# Fail through the caller's die helper when any expected target is absent.
# TODO: Document verify_seeded_indexes_for_user.
# TODO: Document verify_seeded_indexes_for_user.
verify_seeded_indexes_for_user() {
    local user_key="$1"
    local user_email="$2"
    local user_token="$3"
    local indexes_response seed_target target_user_key target_index_name _

    indexes_response=$(api_call_with_token GET /indexes "$user_token")

    for seed_target in "${SEED_INDEX_TARGETS[@]}"; do
        IFS='|' read -r target_user_key target_index_name _ <<<"$seed_target"
        if [ "$target_user_key" != "$user_key" ]; then
            continue
        fi

        if ! printf '%s' "$indexes_response" | TARGET="$target_index_name" python3 -c '
import json, os, sys

payload = json.load(sys.stdin)
items = payload if isinstance(payload, list) else payload.get("indexes", [])
names = {
    item.get("name")
    for item in items
    if isinstance(item, dict) and isinstance(item.get("name"), str)
}
sys.exit(0 if os.environ["TARGET"] in names else 1)
'; then
            die "Seeded index ${target_index_name} is missing from GET /indexes for ${user_email}"
        fi
    done

    log "Verified seeded index names for ${user_email}"
}
