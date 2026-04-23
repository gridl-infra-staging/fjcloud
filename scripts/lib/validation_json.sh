#!/usr/bin/env bash
# Shared JSON/timing helpers for validation scripts.
# Sourced by validate-stripe.sh, local-signoff-commerce.sh, and others.
set -euo pipefail

validation_ms_now() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

validation_json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

# Initialize step-tracking state at source-time.
# Callers must source this library before they begin timed work, otherwise
# elapsed_ms will include pre-validation setup time.
VALIDATION_START_MS="$(validation_ms_now)"
VALIDATION_STEPS_JSON=""

validation_append_step() {
    local name="$1" passed="$2" detail="$3"
    local detail_json
    detail_json="$(validation_json_escape "$detail")"
    local step="{\"name\":\"$name\",\"passed\":$passed,\"detail\":$detail_json}"
    if [ -z "$VALIDATION_STEPS_JSON" ]; then
        VALIDATION_STEPS_JSON="$step"
    else
        VALIDATION_STEPS_JSON="$VALIDATION_STEPS_JSON,$step"
    fi
}

validation_emit_result() {
    local passed="$1"
    local elapsed_ms
    elapsed_ms=$(( $(validation_ms_now) - VALIDATION_START_MS ))
    printf '{"passed":%s,"steps":[%s],"elapsed_ms":%s}\n' "$passed" "$VALIDATION_STEPS_JSON" "$elapsed_ms"
}

validation_json_get_field() {
    local json_body="$1"
    local field="$2"
    python3 - "$json_body" "$field" <<'PY' || true
import json
import sys

body = sys.argv[1]
field = sys.argv[2]
try:
    data = json.loads(body)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(field, "")
if value is None:
    print("")
elif isinstance(value, (int, float, bool)):
    print(str(value).lower() if isinstance(value, bool) else str(value))
else:
    print(str(value))
PY
}
