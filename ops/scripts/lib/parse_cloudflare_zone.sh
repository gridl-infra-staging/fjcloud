#!/usr/bin/env bash
# Cloudflare zone-name parser. Sourced by ops/scripts/validate_bootstrap.sh
# and ops/scripts/tests/validate_bootstrap_zone_parser_test.sh.
#
# extract_zone_name <json_blob>  ->  stdout: the .result.name string
# Returns 0 on success, prints empty on failure.
#
# History: was inline in validate_bootstrap.sh until a greedy sed regex
# silently matched .result.plan.name ("Free Website") instead of .result.name
# ("flapjack.foo"). Fix landed in ad592f80; extracted here 2026-05-14 so the
# regression test exercises the SAME code path the script uses.
extract_zone_name() {
  local zone_response="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "${zone_response}" | jq -r '.result.name // empty'
  else
    # Non-greedy: anchor on "result":{...} subtree, then grab the first "name"
    # inside that object. The [^}]* prevents crossing into nested objects
    # like result.plan.
    printf '%s' "${zone_response}" | sed -nE 's/.*"result"[[:space:]]*:[[:space:]]*\{[^}]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1
  fi
}
