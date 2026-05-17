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

assert_ne() {
    local actual="$1" rejected="$2" msg="$3"
    if [ "$actual" = "$rejected" ]; then
        fail "$msg (expected not '$rejected' but got '$actual')"
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

read_file_content() {
    local abs_path="$1"
    cat "$abs_path"
}

assert_file_exists() {
    local abs_path="$1" msg="$2"
    if [ -f "$abs_path" ]; then
        pass "$msg"
    else
        fail "$msg (missing '$abs_path')"
    fi
}

assert_file_line_count_at_most() {
    local abs_path="$1" max_lines="$2" msg="$3"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$abs_path')"
        return
    fi

    local actual_lines
    actual_lines="$(wc -l < "$abs_path" | tr -d ' ')"
    if [ "$actual_lines" -le "$max_lines" ]; then
        pass "$msg"
    else
        fail "$msg ('$abs_path' has $actual_lines lines; expected <= $max_lines)"
    fi
}

assert_file_not_matching_regex() {
    local abs_path="$1" regex="$2" msg="$3"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$abs_path')"
        return
    fi

    if grep -Eiq "$regex" "$abs_path"; then
        fail "$msg (unexpected pattern '$regex' in '$abs_path')"
    else
        pass "$msg"
    fi
}

assert_file_only_comment_or_blank_lines() {
    local abs_path="$1" msg="$2"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$abs_path')"
        return
    fi

    if grep -Ev '^[[:space:]]*($|#)' "$abs_path" >/dev/null; then
        fail "$msg (found non-comment content in '$abs_path')"
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
