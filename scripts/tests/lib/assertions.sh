#!/usr/bin/env bash
# Shared assertions for shell test scripts.
#
# Callers must define:
#   pass "<message>"
#   fail "<message>"

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

assert_not_contains() {
    local actual="$1" rejected_substr="$2" msg="$3"
    if [[ "$actual" == *"$rejected_substr"* ]]; then
        fail "$msg (unexpected substring '$rejected_substr' found)"
    else
        pass "$msg"
    fi
}

assert_valid_json() {
    local payload="$1" msg="$2"
    if python3 - "$payload" <<'PY'
import json
import sys
json.loads(sys.argv[1])
PY
    then
        pass "$msg"
    else
        fail "$msg (payload was not valid JSON)"
    fi
}

assert_json_bool_field() {
    local payload="$1" field_name="$2" expected="$3" msg="$4"
    if python3 - "$payload" "$field_name" "$expected" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
field_name = sys.argv[2]
expected = sys.argv[3].lower() == "true"
if obj.get(field_name) != expected:
    raise SystemExit(1)
PY
    then
        pass "$msg"
    else
        fail "$msg (unexpected '$field_name' value)"
    fi
}
