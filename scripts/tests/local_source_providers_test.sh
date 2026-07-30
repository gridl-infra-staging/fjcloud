#!/usr/bin/env bash
# Red contract test for local disposable Meilisearch and Typesense source providers.
#
# Stage 1 intentionally commits this guard while the compose/up/down harness is
# still missing. It must fail for the missing shared-stack contracts without
# starting ad hoc provider containers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"
# shellcheck source=lib/source_provider_harness.sh
source "$SCRIPT_DIR/lib/source_provider_harness.sh"

FIXTURE_ROOT="$SCRIPT_DIR/fixtures/source-migration"

MEILI_IMAGE="getmeili/meilisearch@sha256:9694a59df43ee3f54b3fda9c5de381a3ee9852678e3e31cadf37d6bddea7fc1b"
TYPESENSE_IMAGE="typesense/typesense:30.2@sha256:610f2d34b1f93d00762869da2c67736775e5798d19a2c8b91b014b8a0cc1e110"
MEILI_CANARY="MEILI_TEST_SECRET_CANARY"
TYPESENSE_CANARY="TYPESENSE_STAGE2_BOOTSTRAP_CANARY"
MEILI_MASTER_KEY_CANARY="meili-stage1-generated-master-key"
TYPESENSE_API_KEY_CANARY="typesense-stage1-generated-api-key"

RUN_ROOT=""
RUN_EVIDENCE_ROOT=""
RUN_LOG_ROOT=""
RUN_CREDENTIAL_ROOT=""
RUN_PROVIDER_STATE_ROOT=""
RUN_TEARDOWN_INVOCATION_ID=""
LOCAL_DEV_UP_OUTPUT=""
LOCAL_DEV_UP_EXIT=0
LOCAL_DEV_DOWN_OUTPUT=""
LOCAL_DEV_DOWN_EXIT=0

json_value() {
    local file="$1" expr="$2"
    python3 - "$file" "$expr" <<'PY'
import json
import sys

missing = object()
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)

for part in sys.argv[2].split("."):
    if value is missing:
        break
    if part.isdigit():
        if not isinstance(value, list) or int(part) >= len(value):
            value = missing
            break
        value = value[int(part)]
    else:
        if not isinstance(value, dict) or part not in value:
            value = missing
            break
        value = value[part]

if value is missing:
    print("__MISSING__")
elif isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
PY
}

json_compact() {
    local file="$1" expr="${2:-}"
    python3 - "$file" "$expr" <<'PY'
import json
import sys

missing = object()
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, json.JSONDecodeError):
    print("__INVALID_JSON__")
    raise SystemExit(0)

if sys.argv[2]:
    for part in sys.argv[2].split("."):
        if value is missing:
            break
        if part.isdigit():
            if not isinstance(value, list) or int(part) >= len(value):
                value = missing
                break
            value = value[int(part)]
        else:
            if not isinstance(value, dict) or part not in value:
                value = missing
                break
            value = value[part]

if value is missing:
    print("__MISSING__")
else:
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

json_documents_match() {
    local expected="$1" actual="$2"
    [ -f "$expected" ] && [ -f "$actual" ] || return 1
    [ "$(json_compact "$expected")" = "$(json_compact "$actual")" ] &&
        [ "$(json_compact "$actual")" != "__INVALID_JSON__" ]
}

json_contract_documents_match() {
    local expected="$1" actual="$2" provider="$3"
    [ -f "$expected" ] && [ -f "$actual" ] || return 1
    python3 - "$expected" "$actual" "$provider" <<'PY'
import json
import sys

expected_path, actual_path, provider = sys.argv[1:]

try:
    with open(expected_path, encoding="utf-8") as handle:
        expected = json.load(handle)
    with open(actual_path, encoding="utf-8") as handle:
        actual = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

if provider == "meilisearch":
    if isinstance(expected, dict):
        expected.pop("cleanup", None)
    if isinstance(actual, dict):
        actual.pop("cleanup", None)

raise SystemExit(0 if expected == actual else 1)
PY
}

assert_json_documents_equal() {
    local actual="$1" expected="$2" msg="$3"
    if json_documents_match "$expected" "$actual"; then
        pass "$msg"
    else
        fail "$msg (complete JSON documents differ)"
    fi
}

assert_json_contract_documents_equal() {
    local actual="$1" expected="$2" provider="$3" msg="$4"
    if json_contract_documents_match "$expected" "$actual" "$provider"; then
        pass "$msg"
    else
        fail "$msg (contract JSON documents differ)"
    fi
}

assert_file_contains_literal() {
    local file="$1" literal="$2" msg="$3"
    if [ ! -f "$file" ]; then
        fail "$msg (missing '$file')"
        return
    fi
    if grep -Fq "$literal" "$file"; then
        pass "$msg"
    else
        fail "$msg (missing literal '$literal' in '$file')"
    fi
}

text_without_literal() {
    local text="$1" literal="$2"
    [[ "$text" != *"$literal"* ]]
}

assert_text_without_literal() {
    local text="$1" literal="$2" msg="$3"
    if text_without_literal "$text" "$literal"; then
        pass "$msg"
    else
        fail "$msg (found unredacted secret)"
    fi
}

phase_log_contains_command_literal() {
    local file="$1" phase="$2" literal="$3"
    [ -f "$file" ] || return 1
    awk -v prefix="$phase|" -v literal="$literal" '
        index($0, prefix) == 1 && index(substr($0, length(prefix) + 1), literal) {
            found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

assert_phase_log_contains_command_literal() {
    local file="$1" phase="$2" literal="$3" msg="$4"
    if phase_log_contains_command_literal "$file" "$phase" "$literal"; then
        pass "$msg"
    else
        fail "$msg (phase '$phase' did not run a command containing '$literal')"
    fi
}

phase_compose_up_starts_services() {
    local file="$1" phase="$2"
    shift 2
    python3 - "$file" "$phase" "$@" <<'PY'
import shlex
import sys

path, phase, *required_services = sys.argv[1:]
started_services = set()
try:
    with open(path, encoding="utf-8") as handle:
        lines = list(handle)
except OSError:
    raise SystemExit(1)

prefix = f"{phase}|"
for raw_line in lines:
    if not raw_line.startswith(prefix):
        continue
    try:
        command = shlex.split(raw_line[len(prefix):])
    except ValueError:
        continue
    if not command or command[0] != "compose" or "up" not in command:
        continue
    up_index = command.index("up")
    if "-d" not in command[up_index + 1:]:
        continue
    started_services.update(
        token
        for token in command[up_index + 1:]
        if token in required_services
    )

raise SystemExit(0 if set(required_services) <= started_services else 1)
PY
}

phase_compose_down_ran() {
    local file="$1" phase="$2"
    python3 - "$file" "$phase" <<'PY'
import shlex
import sys

path, phase = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        lines = list(handle)
except OSError:
    raise SystemExit(1)

prefix = f"{phase}|"
for raw_line in lines:
    if not raw_line.startswith(prefix):
        continue
    try:
        command = shlex.split(raw_line[len(prefix):])
    except ValueError:
        continue
    if command[:2] == ["compose", "down"]:
        raise SystemExit(0)

raise SystemExit(1)
PY
}

assert_phase_compose_down_ran() {
    local file="$1" phase="$2" msg="$3"
    if phase_compose_down_ran "$file" "$phase"; then
        pass "$msg"
    else
        fail "$msg (phase '$phase' did not run docker compose down)"
    fi
}

teardown_observed_provider_transitions() {
    local file="$1" phase="$2" invocation_id="$3"
    shift 3
    python3 - "$file" "$phase" "$invocation_id" "$@" <<'PY'
import sys

path, phase, invocation_id, *required_services = sys.argv[1:]
expected = {
    f"{phase}|{invocation_id}|{service}|presentBefore:true|presentAfter:false"
    for service in required_services
}
try:
    with open(path, encoding="utf-8") as handle:
        observed = {line.rstrip("\n") for line in handle}
except OSError:
    raise SystemExit(1)

raise SystemExit(0 if expected <= observed else 1)
PY
}

assert_teardown_observed_provider_transitions() {
    local file="$1" phase="$2" invocation_id="$3" msg="$4"
    shift 4
    if teardown_observed_provider_transitions \
        "$file" "$phase" "$invocation_id" "$@"
    then
        pass "$msg"
    else
        fail "$msg (teardown did not observe every provider present before and absent after: $*)"
    fi
}

assert_phase_compose_up_starts_services() {
    local file="$1" phase="$2" msg="$3"
    shift 3
    if phase_compose_up_starts_services "$file" "$phase" "$@"; then
        pass "$msg"
    else
        fail "$msg (phase '$phase' did not compose up all required services: $*)"
    fi
}

assert_tree_without_literal() {
    local path="$1" literal="$2" msg="$3"
    if [ ! -e "$path" ]; then
        fail "$msg (missing scanned path '$path')"
        return
    fi
    if grep -R -Fq "$literal" "$path"; then
        fail "$msg (found unredacted '$literal' under '$path')"
    else
        pass "$msg"
    fi
}

compose_contract_errors() {
    local compose_file="$1" service="$2" image="$3" port_var="$4" container_port="$5"
    python3 - "$compose_file" "$service" "$image" "$port_var" "$container_port" <<'PY'
import os
import re
import shlex
import sys
import yaml

compose_file, service_name, expected_image, port_var, container_port = sys.argv[1:]
with open(compose_file, encoding="utf-8") as handle:
    payload = yaml.safe_load(handle) or {}

service = (payload.get("services") or {}).get(service_name)
errors = []
if not isinstance(service, dict):
    errors.append(f"missing service {service_name}")
else:
    profiles = service.get("profiles")
    if profiles != ["source-providers"]:
        errors.append(f"profiles must equal ['source-providers'], got {profiles!r}")

    image = service.get("image")
    if image != expected_image:
        errors.append(f"image must equal {expected_image!r}, got {image!r}")

    expected_port = f"${{{port_var}:-{container_port}}}:{container_port}"
    ports = service.get("ports")
    if not isinstance(ports, list) or expected_port not in [str(port) for port in ports]:
        errors.append(f"ports must include {expected_port!r}, got {ports!r}")

    healthcheck = service.get("healthcheck")
    test = healthcheck.get("test") if isinstance(healthcheck, dict) else None
    expected_health_url = f"http://localhost:{container_port}/health"

    def has_curl_failure_probe(command):
        if not command:
            return False
        executable = command[0]
        curl_args = command[1:]
        has_fail_flag = any(
            arg == "--fail"
            or (
                arg.startswith("-")
                and not arg.startswith("--")
                and "f" in arg[1:]
                and all(character.isalpha() for character in arg[1:])
            )
            for arg in curl_args
        )
        return (
            os.path.basename(executable) == "curl"
            and expected_health_url in curl_args
            and has_fail_flag
        )

    def direct_command(segment):
        while segment and "=" in segment[0] and not segment[0].startswith("-"):
            segment = segment[1:]
        if segment and segment[0] == "env":
            segment = segment[1:]
            while segment and "=" in segment[0] and not segment[0].startswith("-"):
                segment = segment[1:]
        return segment

    def shell_commands_and_operators(command_string):
        try:
            lexer = shlex.shlex(command_string, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            return [], []
        segments = []
        operators = []
        current = []
        for token in tokens:
            if token in {";", "&&", "||", "|"}:
                if not current:
                    return [], []
                segments.append(current)
                operators.append(token)
                current = []
                continue
            current.append(token)
        if not current or len(operators) != len(segments):
            return [], []
        segments.append(current)
        return segments, operators

    def setup_segment(segment):
        command = direct_command(segment)
        return not command or os.path.basename(command[0]) in {"set", ":", "true"}

    def direct_shell_probe_is_failure_coupled(command_string):
        segments, operators = shell_commands_and_operators(command_string)
        if not segments:
            return False

        curl_indexes = [
            index
            for index, segment in enumerate(segments)
            if has_curl_failure_probe(direct_command(segment))
        ]
        if len(curl_indexes) != 1:
            return False
        curl_index = curl_indexes[0]

        if not all(setup_segment(segment) for segment in segments[:curl_index]):
            return False
        if any(operator not in {";", "&&"} for operator in operators[:curl_index]):
            return False

        suffix_segments = segments[curl_index + 1 :]
        suffix_operators = operators[curl_index:]
        if not suffix_segments:
            return True
        return (
            len(suffix_segments) == 1
            and suffix_operators == ["||"]
            and len(suffix_segments[0]) == 2
            and suffix_segments[0][0] == "exit"
            and suffix_segments[0][1].isdigit()
            and int(suffix_segments[0][1]) != 0
        )

    def option_has_value(arguments, short_name, long_name, expected_value):
        for index, argument in enumerate(arguments):
            if argument in {short_name, long_name}:
                if index + 1 < len(arguments) and arguments[index + 1] == expected_value:
                    return True
            if argument.startswith(f"{long_name}=") and argument.split("=", 1)[1] == expected_value:
                return True
        return False

    def status_test_accepts_only_http_200(test_command, variable_name):
        try:
            tokens = shlex.split(test_command, posix=True)
        except ValueError:
            return False
        if not tokens or tokens[0] != "test":
            return False

        escaped_reference = f"$${variable_name}"
        terms = []
        current = []
        for token in tokens[1:]:
            if token == "-o":
                if not current:
                    return False
                terms.append(current)
                current = []
            else:
                current.append(token)
        if not current:
            return False
        terms.append(current)

        for term in terms:
            if len(term) != 3 or term[0] != escaped_reference or term[1] not in {"=", "=="}:
                return False
            if term[2] != "200":
                return False
        return True

    def status_assignment_probe_is_failure_coupled(command_string):
        match = re.fullmatch(
            r"\s*([A-Za-z_][A-Za-z0-9_]*)=\${1,2}\("
            r"(.*?)\)\s*;\s*(test\s+.+?)\s*",
            command_string,
        )
        if not match:
            return False
        variable_name, probe_command, test_command = match.groups()
        segments, operators = shell_commands_and_operators(probe_command)
        if (
            len(segments) != 2
            or operators != ["||"]
            or direct_command(segments[1]) != ["true"]
        ):
            return False

        curl_command = direct_command(segments[0])
        if not curl_command or os.path.basename(curl_command[0]) != "curl":
            return False
        curl_args = curl_command[1:]
        captures_http_status = option_has_value(
            curl_args, "-w", "--write-out", "%{http_code}"
        )
        discards_response_body = option_has_value(
            curl_args, "-o", "--output", "/dev/null"
        )
        return (
            expected_health_url in curl_args
            and captures_http_status
            and discards_response_body
            and status_test_accepts_only_http_200(test_command, variable_name)
        )

    def bash_dev_tcp_probe_is_failure_coupled(command_string):
        try:
            tokens = shlex.split(command_string, posix=True)
        except ValueError:
            return False
        if len(tokens) != 3 or os.path.basename(tokens[0]) != "bash":
            return False
        if "e" not in tokens[1] or "c" not in tokens[1]:
            return False
        script = tokens[2]
        disallowed_success_tails = ("|| true", "; true", "| true", "| cat")
        return (
            f"/dev/tcp/127.0.0.1/{container_port}" in script
            and "GET /health HTTP/1.1" in script
            and "grep -q" in script
            and "200 OK" in script
            and not any(tail in script for tail in disallowed_success_tails)
        )

    healthcheck_is_executable = False
    if isinstance(test, list) and len(test) >= 3 and test[0] == "CMD":
        healthcheck_is_executable = has_curl_failure_probe([str(part) for part in test[1:]])
    elif (
        isinstance(test, list)
        and len(test) == 2
        and test[0] == "CMD-SHELL"
        and isinstance(test[1], str)
    ):
        healthcheck_is_executable = (
            direct_shell_probe_is_failure_coupled(test[1])
            or status_assignment_probe_is_failure_coupled(test[1])
            or bash_dev_tcp_probe_is_failure_coupled(test[1])
        )
    if not healthcheck_is_executable:
        errors.append(
            f"healthcheck must execute a failure-coupled probe against "
            f"{expected_health_url}, got {test!r}"
        )

for error in errors:
    print(error)
raise SystemExit(1 if errors else 0)
PY
}

assert_compose_provider_contract() {
    local service="$1" image="$2" port_var="$3" container_port="$4"
    local errors
    errors="$(compose_contract_errors "$REPO_ROOT/docker-compose.yml" "$service" "$image" "$port_var" "$container_port" 2>&1)" && {
        pass "compose declaration: '$service' has exact profile, digest image, parameterised port, and healthcheck"
        return
    }
    fail "compose declaration: docker-compose.yml must semantically declare '$service' ($errors)"
}

assert_compose_semantic_parser_rejects_false_positive_specimens() {
    local tmp_dir bad_compose healthcheck_compose errors
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN
    bad_compose="$tmp_dir/docker-compose.yml"
    healthcheck_compose="$tmp_dir/healthchecks.yml"

    cat > "$bad_compose" <<EOF
services:
  meilisearch:
    # profiles: ["source-providers"]
    image: busybox
    ports:
      - "9999:9999"
    healthcheck: {}
  unrelated:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports:
      - "\${LOCAL_MEILISEARCH_PORT:-7700}:7700"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:7700/health"]
EOF

    errors="$(compose_contract_errors "$bad_compose" "meilisearch" "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" 2>&1)" && {
        fail "compose declaration: semantic parser rejects commented or unrelated provider declarations"
        return
    }
    assert_contains "$errors" "profiles must equal" \
        "compose declaration: semantic parser rejects commented profile text"
    assert_contains "$errors" "image must equal" \
        "compose declaration: semantic parser rejects unrelated image text"
    assert_contains "$errors" "ports must include" \
        "compose declaration: semantic parser rejects unrelated port text"
    assert_contains "$errors" "healthcheck must execute a failure-coupled probe" \
        "compose declaration: semantic parser rejects empty healthcheck text"

    cat > "$healthcheck_compose" <<EOF
services:
  valid_cmd:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:7700/health"]
  valid_shell:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7700/health"]
  valid_shell_control_flow:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7700/health || exit 1"]
  valid_shell_setup:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "set -e; curl --fail --silent http://localhost:7700/health >/dev/null"]
  valid_shell_status_assignment:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "code=\$\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:7700/health || true); test \"\$\$code\" = 200"]
  valid_bash_dev_tcp:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "bash -ec 'exec 3<>/dev/tcp/127.0.0.1/7700; printf \"GET /health HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n\" >&3; grep -q \"200 OK\" <&3'"]
  status_assignment_accepts_failure_status:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "code=\$\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:7700/health || true); test \"\$\$code\" = 200 -o \"\$\$code\" = 500"]
  single_dollar_status_reference:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "code=\$\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:7700/health || true); test \"\$code\" = 200"]
  inert:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD", "echo", "curl", "-fsS", "http://localhost:7700/health"]
  always_failing:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "false; curl -fsS http://localhost:7700/health"]
  masked_pipeline:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7700/health | cat"]
  masked_or_true:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7700/health || true"]
  masked_success_tail:
    profiles: ["source-providers"]
    image: $MEILI_IMAGE
    ports: ["\${LOCAL_MEILISEARCH_PORT:-7700}:7700"]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7700/health; true"]
EOF

    if compose_contract_errors "$healthcheck_compose" "valid_cmd" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        pass "compose declaration: executable CMD curl healthcheck is accepted"
    else
        fail "compose declaration: executable CMD curl healthcheck is accepted"
    fi
    if compose_contract_errors "$healthcheck_compose" "valid_shell" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        pass "compose declaration: executable CMD-SHELL curl healthcheck is accepted"
    else
        fail "compose declaration: executable CMD-SHELL curl healthcheck is accepted"
    fi
    if compose_contract_errors "$healthcheck_compose" "valid_shell_control_flow" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        pass "compose declaration: executable CMD-SHELL curl healthcheck with control flow is accepted"
    else
        fail "compose declaration: executable CMD-SHELL curl healthcheck with control flow is accepted"
    fi
    if compose_contract_errors "$healthcheck_compose" "valid_shell_setup" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        pass "compose declaration: executable CMD-SHELL curl healthcheck after shell setup is accepted"
    else
        fail "compose declaration: executable CMD-SHELL curl healthcheck after shell setup is accepted"
    fi
    if compose_contract_errors "$healthcheck_compose" "valid_shell_status_assignment" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        pass "compose declaration: CMD-SHELL curl status assignment and test healthcheck is accepted"
    else
        fail "compose declaration: CMD-SHELL curl status assignment and test healthcheck is accepted"
    fi
    if compose_contract_errors "$healthcheck_compose" "valid_bash_dev_tcp" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        pass "compose declaration: CMD-SHELL bash /dev/tcp HTTP healthcheck is accepted"
    else
        fail "compose declaration: CMD-SHELL bash /dev/tcp HTTP healthcheck is accepted"
    fi
    if compose_contract_errors "$healthcheck_compose" "status_assignment_accepts_failure_status" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: CMD-SHELL status assignment accepting non-200 statuses is rejected"
    else
        pass "compose declaration: CMD-SHELL status assignment accepting non-200 statuses is rejected"
    fi
    if compose_contract_errors "$healthcheck_compose" "single_dollar_status_reference" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: CMD-SHELL single-dollar status reference is rejected"
    else
        pass "compose declaration: CMD-SHELL single-dollar status reference is rejected"
    fi
    if compose_contract_errors "$healthcheck_compose" "inert" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: inert command containing curl text is rejected"
    else
        pass "compose declaration: inert command containing curl text is rejected"
    fi
    if compose_contract_errors "$healthcheck_compose" "always_failing" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: always-failing command containing curl text is rejected"
    else
        pass "compose declaration: always-failing command containing curl text is rejected"
    fi
    if compose_contract_errors "$healthcheck_compose" "masked_pipeline" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: CMD-SHELL curl pipeline with masked exit status is rejected"
    else
        pass "compose declaration: CMD-SHELL curl pipeline with masked exit status is rejected"
    fi
    if compose_contract_errors "$healthcheck_compose" "masked_or_true" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: CMD-SHELL curl or-true masking is rejected"
    else
        pass "compose declaration: CMD-SHELL curl or-true masking is rejected"
    fi
    if compose_contract_errors "$healthcheck_compose" "masked_success_tail" \
        "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700" >/dev/null
    then
        fail "compose declaration: CMD-SHELL curl unconditional-success tail is rejected"
    else
        pass "compose declaration: CMD-SHELL curl unconditional-success tail is rejected"
    fi
}

assert_command_log_matchers_are_semantic() {
    local tmp_dir valid_log wrong_phase_log partial_log
    tmp_dir="$(mktemp -d)"
    valid_log="$tmp_dir/valid.log"
    wrong_phase_log="$tmp_dir/wrong_phase.log"
    partial_log="$tmp_dir/partial.log"

    cat > "$valid_log" <<'EOF'
local-dev-up|compose up -d meilisearch typesense
local-dev-up|-fsS --retry 3 http://127.0.0.1:17700/health
EOF
    cat > "$wrong_phase_log" <<'EOF'
local-dev-down|-fsS http://127.0.0.1:17700/health
EOF
    cat > "$partial_log" <<'EOF'
local-dev-up|compose up -d meilisearch
EOF

    if phase_log_contains_command_literal \
        "$valid_log" "local-dev-up" "http://127.0.0.1:17700/health"
    then
        pass "shared-path reachability matcher: health URL may follow standard curl flags"
    else
        fail "shared-path reachability matcher: health URL may follow standard curl flags"
    fi
    if phase_log_contains_command_literal \
        "$wrong_phase_log" "local-dev-up" "http://127.0.0.1:17700/health"
    then
        fail "shared-path reachability matcher: health URL from the wrong phase is rejected"
    else
        pass "shared-path reachability matcher: health URL from the wrong phase is rejected"
    fi
    if phase_compose_up_starts_services \
        "$valid_log" "local-dev-up" "meilisearch" "typesense"
    then
        pass "shared-path reachability matcher: grouped compose startup owns both providers"
    else
        fail "shared-path reachability matcher: grouped compose startup owns both providers"
    fi
    if phase_compose_up_starts_services \
        "$partial_log" "local-dev-up" "meilisearch" "typesense"
    then
        fail "shared-path reachability matcher: partial compose startup is rejected"
    else
        pass "shared-path reachability matcher: partial compose startup is rejected"
    fi
    rm -rf "$tmp_dir"
}

assert_json_compact_reports_bad_evidence() {
    local tmp_dir incomplete_file malformed_file
    tmp_dir="$(mktemp -d)"
    incomplete_file="$tmp_dir/incomplete.json"
    malformed_file="$tmp_dir/malformed.json"

    printf '%s\n' '{"documents":{}}' > "$incomplete_file"
    printf '%s\n' '{"documents":' > "$malformed_file"

    assert_eq "$(json_compact "$incomplete_file" documents.beforeMutation)" "__MISSING__" \
        "seeded exactness matcher: incomplete evidence returns a named missing sentinel"
    assert_eq "$(json_compact "$malformed_file" documents.beforeMutation)" "__INVALID_JSON__" \
        "seeded exactness matcher: malformed evidence returns a named invalid-JSON sentinel"
    rm -rf "$tmp_dir"
}

assert_complete_seeded_bundle_mutation_specimens() {
    local tmp_dir meili_expected typesense_expected specimen label
    tmp_dir="$(mktemp -d)"
    meili_expected="$FIXTURE_ROOT/meilisearch/expected_bundle.json"
    typesense_expected="$FIXTURE_ROOT/typesense/expected_bundle.json"

    python3 - "$meili_expected" "$typesense_expected" "$tmp_dir" <<'PY'
import copy
import json
import pathlib
import sys

meili_path, typesense_path, output_dir = sys.argv[1:]
output = pathlib.Path(output_dir)
with open(meili_path, encoding="utf-8") as handle:
    meili = json.load(handle)
with open(typesense_path, encoding="utf-8") as handle:
    typesense = json.load(handle)

mutations = {}

value = copy.deepcopy(meili)
value["documents"]["afterMutation"].pop()
mutations["meili_after_mutation.json"] = value

value = copy.deepcopy(meili)
value["documents"]["countBefore"] = 30
value["documents"]["countAfter"] = 40
mutations["meili_counts.json"] = value

value = copy.deepcopy(meili)
value["documents"]["inferred"].pop()
mutations["meili_inferred.json"] = value

value = copy.deepcopy(typesense)
value["source"]["synonym_sets"] = []
mutations["typesense_synonym_sets.json"] = value

value = copy.deepcopy(typesense)
value["source"]["curation_sets"] = []
mutations["typesense_curation_sets.json"] = value

for name, payload in mutations.items():
    with open(output / name, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
PY

    for specimen in \
        meili_after_mutation \
        meili_counts \
        meili_inferred \
        typesense_synonym_sets \
        typesense_curation_sets
    do
        case "$specimen" in
            meili_*) expected="$meili_expected" ;;
            typesense_*) expected="$typesense_expected" ;;
        esac
        label="${specimen//_/ }"
        provider="${specimen%%_*}"
        if json_contract_documents_match "$expected" "$tmp_dir/$specimen.json" "$provider"; then
            fail "seeded exactness mutation: $label drift is rejected"
        else
            pass "seeded exactness mutation: $label drift is rejected"
        fi
    done
    rm -rf "$tmp_dir"
}

assert_producer_metadata_is_not_seeded_contract() {
    local tmp_dir meili_expected changed_cleanup omitted_cleanup
    tmp_dir="$(mktemp -d)"
    meili_expected="$FIXTURE_ROOT/meilisearch/expected_bundle.json"
    changed_cleanup="$tmp_dir/meili_changed_cleanup.json"
    omitted_cleanup="$tmp_dir/meili_omitted_cleanup.json"

    python3 - "$meili_expected" "$changed_cleanup" "$omitted_cleanup" <<'PY'
import copy
import json
import sys

expected_path, changed_path, omitted_path = sys.argv[1:]
with open(expected_path, encoding="utf-8") as handle:
    expected = json.load(handle)

changed = copy.deepcopy(expected)
changed["cleanup"] = {
    "containerName": "fjcloud_local_meilisearch",
    "tempDir": ".local/source-migration/meilisearch",
    "hostPort": 17700,
}

omitted = copy.deepcopy(expected)
omitted.pop("cleanup", None)

for path, payload in [(changed_path, changed), (omitted_path, omitted)]:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
PY

    if json_contract_documents_match "$meili_expected" "$changed_cleanup" "meilisearch"; then
        pass "seeded exactness matcher: Meilisearch producer cleanup metadata may differ"
    else
        fail "seeded exactness matcher: Meilisearch producer cleanup metadata may differ"
    fi
    if json_contract_documents_match "$meili_expected" "$omitted_cleanup" "meilisearch"; then
        pass "seeded exactness matcher: Meilisearch producer cleanup metadata may be omitted"
    else
        fail "seeded exactness matcher: Meilisearch producer cleanup metadata may be omitted"
    fi
    rm -rf "$tmp_dir"
}

assert_seed_evidence_is_derived_from_payloads() {
    local tmp_dir runtime_dir meili_expected meili_output typesense_expected typesense_output
    tmp_dir="$(mktemp -d)"
    runtime_dir="$tmp_dir/runtime"
    meili_expected="$FIXTURE_ROOT/meilisearch/expected_bundle.json"
    meili_output="$tmp_dir/meili_output.json"
    typesense_expected="$FIXTURE_ROOT/typesense/expected_bundle.json"
    typesense_output="$tmp_dir/typesense_output.json"

    write_mock_provider_capture_payloads "$runtime_dir"

    python3 "$REPO_ROOT/scripts/lib/local_source_provider_evidence.py" \
        "$meili_expected" \
        "$meili_output" \
        "$typesense_expected" \
        "$typesense_output" \
        "$runtime_dir"

    assert_json_contract_documents_equal "$meili_output" "$meili_expected" "meilisearch" \
        "seeded exactness: Meilisearch evidence is rebuilt from captured provider state"
    assert_json_contract_documents_equal "$typesense_output" "$typesense_expected" "typesense" \
        "seeded exactness: Typesense evidence is rebuilt from captured provider state"

    python3 - "$runtime_dir/meili_configured_after_capture.json" "$runtime_dir/typesense_capture_synonym_set.json" <<'PY'
import json
import sys

meili_path, typesense_path = sys.argv[1:]
with open(meili_path, encoding="utf-8") as handle:
    meili = json.load(handle)
meili["results"][3]["price"] = 999
with open(meili_path, "w", encoding="utf-8") as handle:
    json.dump(meili, handle)

with open(typesense_path, encoding="utf-8") as handle:
    typesense = json.load(handle)
typesense["items"][0]["synonyms"] = ["drifted-synonym"]
with open(typesense_path, "w", encoding="utf-8") as handle:
    json.dump(typesense, handle)
PY

    python3 "$REPO_ROOT/scripts/lib/local_source_provider_evidence.py" \
        "$meili_expected" \
        "$meili_output" \
        "$typesense_expected" \
        "$typesense_output" \
        "$runtime_dir"

    if json_contract_documents_match "$meili_expected" "$meili_output" "meilisearch"; then
        fail "seeded exactness: Meilisearch capture drift must change the rebuilt evidence"
    else
        pass "seeded exactness: Meilisearch capture drift must change the rebuilt evidence"
    fi
    if json_contract_documents_match "$typesense_expected" "$typesense_output" "typesense"; then
        fail "seeded exactness: Typesense capture drift must change the rebuilt evidence"
    else
        pass "seeded exactness: Typesense capture drift must change the rebuilt evidence"
    fi
    rm -rf "$tmp_dir"
}

assert_secret_output_matcher_rejects_leak_specimen() {
    if text_without_literal \
        "captured output: $MEILI_MASTER_KEY_CANARY" \
        "$MEILI_MASTER_KEY_CANARY"
    then
        fail "secret absence matcher: captured local-dev output leak is detectable"
    else
        pass "secret absence matcher: captured local-dev output leak is detectable"
    fi
}

assert_teardown_matchers_are_owned() {
    local tmp_dir valid_calls wrong_phase_calls inert_calls valid_state missing_start_state invocation_id
    tmp_dir="$(mktemp -d)"
    valid_calls="$tmp_dir/valid_calls.log"
    wrong_phase_calls="$tmp_dir/wrong_phase_calls.log"
    inert_calls="$tmp_dir/inert_calls.log"
    valid_state="$tmp_dir/valid_state.log"
    missing_start_state="$tmp_dir/missing_start_state.log"
    invocation_id="mutation-down-id"

    printf '%s\n' "local-dev-down|compose down -v" > "$valid_calls"
    printf '%s\n' "local-dev-up|compose down -v" > "$wrong_phase_calls"
    printf '%s\n' "local-dev-down|compose echo down" > "$inert_calls"
    printf '%s\n' \
        "local-dev-down|$invocation_id|meilisearch|presentBefore:true|presentAfter:false" \
        "local-dev-down|$invocation_id|typesense|presentBefore:true|presentAfter:false" \
        > "$valid_state"
    printf '%s\n' \
        "local-dev-down|$invocation_id|meilisearch|presentBefore:false|presentAfter:false" \
        "local-dev-down|$invocation_id|typesense|presentBefore:false|presentAfter:false" \
        > "$missing_start_state"

    if phase_compose_down_ran "$valid_calls" "local-dev-down"; then
        pass "post-local-dev-down residue matcher: final down-phase compose teardown is accepted"
    else
        fail "post-local-dev-down residue matcher: final down-phase compose teardown is accepted"
    fi
    if phase_compose_down_ran "$wrong_phase_calls" "local-dev-down"; then
        fail "post-local-dev-down residue matcher: up-phase pre-clean is rejected"
    else
        pass "post-local-dev-down residue matcher: up-phase pre-clean is rejected"
    fi
    if phase_compose_down_ran "$inert_calls" "local-dev-down"; then
        fail "post-local-dev-down residue matcher: inert command containing down text is rejected"
    else
        pass "post-local-dev-down residue matcher: inert command containing down text is rejected"
    fi
    if teardown_observed_provider_transitions \
        "$valid_state" "local-dev-down" "$invocation_id" meilisearch typesense
    then
        pass "post-local-dev-down residue matcher: observed provider removal is accepted"
    else
        fail "post-local-dev-down residue matcher: observed provider removal is accepted"
    fi
    if teardown_observed_provider_transitions \
        "$missing_start_state" "local-dev-down" "$invocation_id" meilisearch typesense
    then
        fail "post-local-dev-down residue matcher: no-container teardown is rejected"
    else
        pass "post-local-dev-down residue matcher: no-container teardown is rejected"
    fi
    rm -rf "$tmp_dir"
}

assert_fixture_imports_are_exact() {
    local meili_bundle="$FIXTURE_ROOT/meilisearch/expected_bundle.json"
    local typesense_bundle="$FIXTURE_ROOT/typesense/expected_bundle.json"
    local restricted_probes="$FIXTURE_ROOT/meilisearch/restricted_key_action_probes.json"

    assert_file_exists "$FIXTURE_ROOT/meilisearch/PROVENANCE.md" \
        "fixture import: Meilisearch provenance exists"
    assert_file_exists "$FIXTURE_ROOT/typesense/PROVENANCE.md" \
        "fixture import: Typesense provenance exists"
    assert_file_contains_literal "$FIXTURE_ROOT/meilisearch/PROVENANCE.md" \
        "Producer commit SHA: \`37d03380994a1185e5c30571936d227e6da0b9df\`" \
        "fixture import: Meilisearch provenance records producer SHA only"
    assert_file_contains_literal "$FIXTURE_ROOT/typesense/PROVENANCE.md" \
        "Producer commit SHA: \`37d03380994a1185e5c30571936d227e6da0b9df\`" \
        "fixture import: Typesense provenance records producer SHA only"

    assert_eq "$(json_value "$meili_bundle" source.image)" "$MEILI_IMAGE" \
        "fixture import: Meilisearch expected bundle keeps the digest-pinned image"
    assert_eq "$(json_value "$meili_bundle" documents.countBefore)" "3" \
        "fixture import: Meilisearch hand-calculated countBefore is preserved"
    assert_eq "$(json_value "$meili_bundle" documents.beforeMutation.2.sku)" "SKU-003" \
        "fixture import: Meilisearch stable SKU specimen is preserved"
    assert_eq "$(json_value "$meili_bundle" settings.synonyms.wrench.0)" "spanner" \
        "fixture import: Meilisearch synonym exact value is preserved"
    assert_eq "$(json_value "$restricted_probes" probes.8.action)" "snapshots.create" \
        "fixture import: Meilisearch restricted-key write probe is preserved"

    assert_eq "$(json_value "$typesense_bundle" contract.image_reference)" "typesense/typesense:30.2" \
        "fixture import: Typesense expected bundle keeps the image reference"
    assert_eq "$(json_value "$typesense_bundle" contract.image_digest)" "sha256:610f2d34b1f93d00762869da2c67736775e5798d19a2c8b91b014b8a0cc1e110" \
        "fixture import: Typesense expected bundle keeps the digest pin"
    assert_eq "$(json_value "$typesense_bundle" source.collections.1.name)" "fj_ts_migration_products" \
        "fixture import: Typesense products collection name is preserved"
    assert_eq "$(json_value "$typesense_bundle" source.aliases.0.collection_name)" "fj_ts_migration_products" \
        "fixture import: Typesense alias target is preserved"
}

assert_shared_stack_reachability_contract() {
    assert_eq "$LOCAL_DEV_UP_EXIT" "0" \
        "shared-path reachability: scripts/local-dev-up.sh exits successfully under the hermetic specimen"
    assert_eq "$LOCAL_DEV_DOWN_EXIT" "0" \
        "post-local-dev-down residue: scripts/local-dev-down.sh exits successfully under the hermetic specimen"
    assert_phase_compose_up_starts_services "$RUN_ROOT/docker_calls.log" "local-dev-up" \
        "shared-path reachability: scripts/local-dev-up.sh owns compose startup for both providers" \
        "meilisearch" "typesense"
    assert_phase_log_contains_command_literal "$RUN_ROOT/curl_calls.log" "local-dev-up" "http://127.0.0.1:17700/health" \
        "shared-path reachability: scripts/local-dev-up.sh owns the Meilisearch health probe on LOCAL_MEILISEARCH_PORT"
    assert_phase_log_contains_command_literal "$RUN_ROOT/curl_calls.log" "local-dev-up" "http://127.0.0.1:18108/health" \
        "shared-path reachability: scripts/local-dev-up.sh owns the Typesense health probe on LOCAL_TYPESENSE_PORT"
    assert_phase_compose_down_ran "$RUN_ROOT/docker_calls.log" "local-dev-down" \
        "post-local-dev-down residue: scripts/local-dev-down.sh owns compose teardown"
    assert_teardown_observed_provider_transitions \
        "$RUN_ROOT/teardown_state.log" \
        "local-dev-down" \
        "$RUN_TEARDOWN_INVOCATION_ID" \
        "post-local-dev-down residue: final teardown observes both providers present before and absent after" \
        "meilisearch" \
        "typesense"
}

assert_seeded_exactness_contract() {
    local meili_expected="$FIXTURE_ROOT/meilisearch/expected_bundle.json"
    local typesense_expected="$FIXTURE_ROOT/typesense/expected_bundle.json"
    local expected_restricted="$FIXTURE_ROOT/meilisearch/restricted_key_action_probes.json"
    local meili_actual="$RUN_EVIDENCE_ROOT/meilisearch/expected_bundle.json"
    local typesense_actual="$RUN_EVIDENCE_ROOT/typesense/expected_bundle.json"
    local actual_restricted="$RUN_EVIDENCE_ROOT/meilisearch/restricted_key_action_probes.json"

    if [ ! -f "$meili_actual" ]; then
        fail "seeded exactness: shared-stack run must surface Meilisearch expected_bundle.json evidence"
    else
        assert_json_contract_documents_equal "$meili_actual" "$meili_expected" "meilisearch" \
            "seeded exactness: local Meilisearch contract data matches every imported expected value"
    fi

    if [ ! -f "$typesense_actual" ]; then
        fail "seeded exactness: shared-stack run must surface Typesense expected_bundle.json evidence"
    else
        assert_json_contract_documents_equal "$typesense_actual" "$typesense_expected" "typesense" \
            "seeded exactness: complete local Typesense bundle matches every imported expected value"
    fi

    if [ ! -f "$actual_restricted" ]; then
        fail "seeded exactness: shared-stack run must surface Meilisearch restricted-key probe evidence"
    else
        assert_eq "$(json_compact "$actual_restricted" probes)" \
            "$(json_compact "$expected_restricted" probes)" \
            "seeded exactness: Meilisearch restricted-key action/method/path probes match imported expectations"
    fi
}

assert_secret_and_residue_contract() {
    local residue_file="$RUN_EVIDENCE_ROOT/residue.json"
    local redaction_file="$RUN_EVIDENCE_ROOT/secret_redaction.json"
    local secret

    for secret in \
        "$MEILI_CANARY" \
        "$TYPESENSE_CANARY" \
        "$MEILI_MASTER_KEY_CANARY" \
        "$TYPESENSE_API_KEY_CANARY"
    do
        assert_tree_without_literal "$RUN_EVIDENCE_ROOT" "$secret" \
            "secret absence: captured evidence tree must not retain $secret"
        assert_tree_without_literal "$RUN_LOG_ROOT" "$secret" \
            "secret absence: provider container logs must not retain $secret"
        assert_tree_without_literal "$RUN_CREDENTIAL_ROOT" "$secret" \
            "secret absence: credential-bearing files must not retain $secret"
        assert_text_without_literal "$LOCAL_DEV_UP_OUTPUT" "$secret" \
            "secret absence: captured scripts/local-dev-up.sh output must not retain $secret"
        assert_text_without_literal "$LOCAL_DEV_DOWN_OUTPUT" "$secret" \
            "secret absence: captured scripts/local-dev-down.sh output must not retain $secret"
    done

    if [ ! -f "$redaction_file" ]; then
        fail "secret absence: shared-stack run must write secret_redaction.json proving all provider secret surfaces were scanned"
    else
        assert_eq "$(json_value "$redaction_file" scannedCapturedEvidenceTree)" "true" \
            "secret absence: redaction proof scans the complete captured-evidence tree"
        assert_eq "$(json_value "$redaction_file" scannedProviderContainerLogs)" "true" \
            "secret absence: redaction proof scans provider container logs"
        assert_eq "$(json_value "$redaction_file" scannedCredentialFiles)" "true" \
            "secret absence: redaction proof scans credential-bearing files"
        assert_eq "$(json_value "$redaction_file" seededCanariesRedacted)" "true" \
            "secret absence: redaction proof covers seeded canaries"
        assert_eq "$(json_value "$redaction_file" generatedCredentialsRedacted)" "true" \
            "secret absence: redaction proof covers generated provider credentials"
    fi

    if [ ! -f "$residue_file" ]; then
        fail "post-local-dev-down residue: shared teardown must write residue.json after scripts/local-dev-down.sh"
        return
    fi

    assert_eq "$(json_value "$residue_file" containerPresent)" "false" \
        "post-local-dev-down residue: containerPresent is false"
    assert_eq "$(json_value "$residue_file" tempDirPresent)" "false" \
        "post-local-dev-down residue: tempDirPresent is false"
    assert_eq "$(json_value "$residue_file" rawLogsPresent)" "false" \
        "post-local-dev-down residue: rawLogsPresent is false"
    assert_eq "$(json_value "$residue_file" credentialFilesPresent)" "false" \
        "post-local-dev-down residue: credentialFilesPresent is false"
    assert_eq "$(json_value "$residue_file" producer)" "scripts/local-dev-down.sh" \
        "post-local-dev-down residue: residue.json names scripts/local-dev-down.sh as producer"
    assert_eq "$(json_value "$residue_file" phase)" "post-local-dev-down" \
        "post-local-dev-down residue: residue.json is tagged after teardown"
    assert_eq "$(json_value "$residue_file" teardownInvocationId)" "$RUN_TEARDOWN_INVOCATION_ID" \
        "post-local-dev-down residue: residue.json uses the down-only teardown invocation id"
}

install_shared_stack_mocks() {
    local bin_dir="$1" state_dir="$2"
    mkdir -p "$bin_dir" "$state_dir"
    write_mock_provider_capture_payloads "$state_dir"

    write_mock_script "$bin_dir/docker" '
set -euo pipefail
echo "${SOURCE_PROVIDER_SCRIPT_PHASE:-unattributed}|$*" >> "'"$RUN_ROOT"'/docker_calls.log"
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "up" ] && [ "${3:-}" = "-d" ]; then
    shift 3
    for service in "$@"; do
        touch "'"$state_dir"'/${service}.started"
    done
    exit 0
fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "ps" ]; then
    shift 2
    if [ "${1:-}" = "--status" ]; then
        shift 2
        if [ "${1:-}" = "--format" ]; then
            shift 2
        fi
        for service in "$@"; do
            [ -f "'"$state_dir"'/${service}.started" ] && printf "%s\n" "$service"
        done
        exit 0
    fi
    service="${1:-}"
    if [ -f "'"$state_dir"'/${service}.started" ]; then
        printf "[{\"Service\":\"%s\",\"Health\":\"healthy\"}]\n" "$service"
    else
        printf "[]\n"
    fi
    exit 0
fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "exec" ]; then
    case "$*" in
        *" -tAc "*"SELECT count("*)
            echo "1"
            ;;
        *" -tAc "*)
            echo "1"
            ;;
    esac
    exit 0
fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "logs" ]; then
    printf "provider logs redacted\n"
    exit 0
fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "down" ]; then
    profiles=",${COMPOSE_PROFILES:-},"
    for service in meilisearch typesense; do
        if [ -f "'"$state_dir"'/${service}.started" ]; then
            present_before=true
        else
            present_before=false
        fi
        case "$profiles" in
            *,source-providers,*)
                rm -f "'"$state_dir"'/${service}.started"
                ;;
        esac
        if [ -f "'"$state_dir"'/${service}.started" ]; then
            present_after=true
        else
            present_after=false
        fi
        printf "%s|%s|%s|presentBefore:%s|presentAfter:%s\n" \
            "${SOURCE_PROVIDER_SCRIPT_PHASE:-unattributed}" \
            "${SOURCE_PROVIDER_TEARDOWN_INVOCATION_ID:-missing}" \
            "$service" \
            "$present_before" \
            "$present_after" \
            >> "'"$RUN_ROOT"'/teardown_state.log"
    done
    rm -f "'"$state_dir"'/"*.started 2>/dev/null || true
    exit 0
fi
exit 0
'

    write_mock_script "$bin_dir/curl" '
set -euo pipefail
args="$*"
echo "${SOURCE_PROVIDER_SCRIPT_PHASE:-unattributed}|$args" >> "'"$RUN_ROOT"'/curl_calls.log"
output="/dev/null"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
output_basename="$(basename "$output")"
if [ -f "'"$state_dir"'/$output_basename" ] && [ "$output" != "/dev/null" ]; then
    cat "'"$state_dir"'/$output_basename" > "$output"
    exit 0
fi
case "$args" in
    *"http://127.0.0.1:17700/health"*|*"http://localhost:7700/health"*)
        [ -f "'"$state_dir"'/meilisearch.started" ]
        ;;
    *"http://127.0.0.1:18108/health"*|*"http://localhost:8108/health"*)
        [ -f "'"$state_dir"'/typesense.started" ]
        ;;
    *)
        exit 0
        ;;
esac
'
    write_mock_script "$bin_dir/nohup" 'exec "$@"'
    write_mock_script "$bin_dir/lsof" 'exit 1'
}

run_shared_stack_specimen() {
    local tmp_dir bin_dir state_dir env_backup local_backup stale_root
    tmp_dir="$(mktemp -d)"
    RUN_ROOT="$tmp_dir"
    RUN_EVIDENCE_ROOT="$tmp_dir/evidence"
    RUN_LOG_ROOT="$tmp_dir/provider-logs"
    RUN_CREDENTIAL_ROOT="$tmp_dir/credential-files"
    RUN_PROVIDER_STATE_ROOT="$tmp_dir/state"
    RUN_TEARDOWN_INVOCATION_ID="stage1-down-$$-$RANDOM"
    bin_dir="$tmp_dir/bin"
    state_dir="$RUN_PROVIDER_STATE_ROOT"
    mkdir -p "$RUN_EVIDENCE_ROOT" "$RUN_LOG_ROOT" "$RUN_CREDENTIAL_ROOT"
    cat > "$RUN_EVIDENCE_ROOT/residue.json" <<'JSON'
{
  "containerPresent": false,
  "tempDirPresent": false,
  "rawLogsPresent": false,
  "credentialFilesPresent": false,
  "producer": "scripts/local-dev-up.sh",
  "phase": "pre-local-dev-down"
}
JSON

    env_backup="$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")"
    local_backup="$(backup_repo_path "$REPO_ROOT/.local" "$tmp_dir/.local.backup")"
    trap 'restore_repo_path "'"$REPO_ROOT/.env.local"'" "'"$env_backup"'"; restore_repo_path "'"$REPO_ROOT/.local"'" "'"$local_backup"'"' EXIT

    mkdir -p "$REPO_ROOT/.local/source-migration/meilisearch" "$REPO_ROOT/.local/source-migration/typesense"
    stale_root="$REPO_ROOT/.local/source-migration"
    cp "$FIXTURE_ROOT/meilisearch/expected_bundle.json" "$stale_root/meilisearch/expected_bundle.json"
    cp "$FIXTURE_ROOT/meilisearch/restricted_key_action_probes.json" "$stale_root/meilisearch/restricted_key_action_probes.json"
    cp "$FIXTURE_ROOT/typesense/expected_bundle.json" "$stale_root/typesense/expected_bundle.json"

    write_local_dev_env_file "$REPO_ROOT/.env.local" \
        "postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev"
    install_shared_stack_mocks "$bin_dir" "$state_dir"

    LOCAL_DEV_UP_OUTPUT=$(
        PATH="$bin_dir:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        COMPOSE_PROFILES="source-providers" \
        LOCAL_DB_PORT=15432 \
        LOCAL_S3_PORT=18333 \
        LOCAL_MAILPIT_UI_PORT=18025 \
        LOCAL_MEILISEARCH_PORT=17700 \
        LOCAL_TYPESENSE_PORT=18108 \
        SOURCE_PROVIDER_EVIDENCE_ROOT="$RUN_EVIDENCE_ROOT" \
        SOURCE_PROVIDER_CREDENTIAL_ROOT="$RUN_CREDENTIAL_ROOT" \
        SOURCE_PROVIDER_SCRIPT_PHASE="local-dev-up" \
        MEILI_MASTER_KEY="$MEILI_MASTER_KEY_CANARY" \
        TYPESENSE_API_KEY="$TYPESENSE_API_KEY_CANARY" \
        MEILI_TEST_SECRET_CANARY="$MEILI_CANARY" \
        TYPESENSE_STAGE2_BOOTSTRAP_CANARY="$TYPESENSE_CANARY" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || LOCAL_DEV_UP_EXIT=$?

    LOCAL_DEV_DOWN_OUTPUT=$(
        PATH="$bin_dir:/usr/bin:/bin" \
        SOURCE_PROVIDER_EVIDENCE_ROOT="$RUN_EVIDENCE_ROOT" \
        SOURCE_PROVIDER_CREDENTIAL_ROOT="$RUN_CREDENTIAL_ROOT" \
        SOURCE_PROVIDER_SCRIPT_PHASE="local-dev-down" \
        SOURCE_PROVIDER_TEARDOWN_INVOCATION_ID="$RUN_TEARDOWN_INVOCATION_ID" \
        bash "$REPO_ROOT/scripts/local-dev-down.sh" --clean 2>&1
    ) || LOCAL_DEV_DOWN_EXIT=$?

    PATH="$bin_dir:/usr/bin:/bin" \
        docker compose logs --no-color meilisearch typesense > "$RUN_LOG_ROOT/provider_container_logs.log" 2>&1 || true

    restore_repo_path "$REPO_ROOT/.env.local" "$env_backup"
    restore_repo_path "$REPO_ROOT/.local" "$local_backup"
    trap - EXIT
}

run_shared_stack_specimen
assert_fixture_imports_are_exact
assert_compose_semantic_parser_rejects_false_positive_specimens
assert_command_log_matchers_are_semantic
assert_json_compact_reports_bad_evidence
assert_complete_seeded_bundle_mutation_specimens
assert_producer_metadata_is_not_seeded_contract
assert_seed_evidence_is_derived_from_payloads
assert_secret_output_matcher_rejects_leak_specimen
assert_teardown_matchers_are_owned
assert_compose_provider_contract "meilisearch" "$MEILI_IMAGE" "LOCAL_MEILISEARCH_PORT" "7700"
assert_compose_provider_contract "typesense" "$TYPESENSE_IMAGE" "LOCAL_TYPESENSE_PORT" "8108"
assert_shared_stack_reachability_contract
assert_seeded_exactness_contract
assert_secret_and_residue_contract

run_test_summary
