#!/usr/bin/env bash
# Structure tests for docs/launch/deployed_proof_refresh_spec.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/assertions.sh"

SPEC_PATH="${DEPLOYED_PROOF_SPEC_PATH:-$REPO_ROOT/docs/launch/deployed_proof_refresh_spec.md}"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

REQUIRED_SECTIONS=(
    "2. Billing / Stripe / webhook"
    "3. Security boundaries"
    "4. Backup / restore + DB integrity"
    "5. HA / multi-tenant isolation"
    "6. Cross-cutting full-stack"
    "Public engine port + unauthenticated engine dashboard on prod AND staging"
    "Deactivate credentials exposed by the public-mirror evidence"
)

REQUIRED_LABELS=(
    "Precondition"
    "Command"
    "Evidence path"
    "Done-condition"
)

repo_relative_path() {
    local path="$1"
    case "$path" in
        "$REPO_ROOT"/*)
            printf '%s\n' "${path#"$REPO_ROOT/"}"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

diagnostic_path() {
    repo_relative_path "$SPEC_PATH"
}

section_body() {
    local spec_path="$1" section="$2"
    python3 - "$spec_path" "$section" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
section = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
heading_re = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
start = None
level = None

for index, line in enumerate(lines):
    match = heading_re.match(line)
    if not match:
        continue
    title = match.group(2).strip("` ")
    if title == section:
        start = index + 1
        level = len(match.group(1))
        break

if start is None:
    raise SystemExit(2)

end = len(lines)
for index in range(start, len(lines)):
    match = heading_re.match(lines[index])
    if match and len(match.group(1)) <= level:
        end = index
        break

print("\n".join(lines[start:end]))
PY
}

extract_script_invocations() {
    local spec_path="$1"
    python3 - "$spec_path" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = re.compile(
    r"(?<![\w./-])((?:bash\s+)?(?:ops/)?scripts/[A-Za-z0-9_./-]*[A-Za-z0-9_-])"
    r"(?=$|[\s`'\"),;:])"
)
seen = set()
for match in pattern.finditer(text):
    invocation = " ".join(match.group(1).split())
    if invocation not in seen:
        seen.add(invocation)
        print(invocation)
PY
}

resolve_repo_script_path() {
    local script_path="$1"
    python3 - "$REPO_ROOT" "$script_path" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
candidate = (repo_root / sys.argv[2]).resolve(strict=False)
try:
    candidate.relative_to(repo_root)
except ValueError:
    raise SystemExit(1)
print(candidate)
PY
}

verify_script_invocation() {
    local invocation="$1" script_path resolved_script_path
    if [[ "$invocation" == bash\ scripts/* || "$invocation" == bash\ ops/scripts/* ]]; then
        script_path="${invocation#bash }"
        if ! resolved_script_path="$(resolve_repo_script_path "$script_path")"; then
            printf 'script invocation escapes repository: %s\n' "$invocation" >&2
            return 1
        fi
        if [ ! -r "$resolved_script_path" ]; then
            printf 'script invocation not readable: %s\n' "$invocation" >&2
            return 1
        fi
        if ! bash -n "$resolved_script_path"; then
            printf 'script invocation fails bash -n: %s\n' "$invocation" >&2
            return 1
        fi
    elif [[ "$invocation" == scripts/* || "$invocation" == ops/scripts/* ]]; then
        script_path="$invocation"
        if ! resolved_script_path="$(resolve_repo_script_path "$script_path")"; then
            printf 'script invocation escapes repository: %s\n' "$invocation" >&2
            return 1
        fi
        if [ ! -f "$resolved_script_path" ] || [ ! -x "$resolved_script_path" ]; then
            printf 'direct script invocation not an executable regular file: %s\n' "$invocation" >&2
            return 1
        fi
    else
        printf 'unsupported script invocation form: %s\n' "$invocation" >&2
        return 1
    fi
}

extract_evidence_families() {
    local spec_path="$1"
    python3 - "$spec_path" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = re.compile(r"docs/runbooks/evidence/([A-Za-z0-9_.-]+)/")
seen = set()
for match in pattern.finditer(text):
    family = match.group(1)
    if family not in seen:
        seen.add(family)
        print(family)
PY
}

assert_required_section() {
    local spec_path="$1" section="$2" body label
    if ! body="$(section_body "$spec_path" "$section")"; then
        printf 'missing required section: %s in %s\n' "$section" "$(repo_relative_path "$spec_path")" >&2
        return 1
    fi

    for label in "${REQUIRED_LABELS[@]}"; do
        if ! printf '%s\n' "$body" |
            rg -q "^[ \t]*(-[ \t]*)?${label}[ \t]*:[ \t]*[^ \t]"; then
            printf 'missing or empty label in section "%s": %s\n' "$section" "$label" >&2
            return 1
        fi
    done
}

assert_missing_capability_section() {
    local spec_path="$1" body
    if ! body="$(section_body "$spec_path" "MISSING CAPABILITY")"; then
        printf 'missing required section: MISSING CAPABILITY in %s\n' "$(repo_relative_path "$spec_path")" >&2
        return 1
    fi
    if ! printf '%s\n' "$body" | rg -q '[^[:space:]]'; then
        printf 'empty required section: MISSING CAPABILITY in %s\n' "$(repo_relative_path "$spec_path")" >&2
        return 1
    fi
}

validate_spec() {
    local spec_path="$1" section invocation family
    local sections_found=0 commands_extracted=0 commands_verified=0
    local evidence_families_extracted=0 evidence_families_verified=0 validation_failed=0

    if [ ! -s "$spec_path" ]; then
        printf 'missing or empty deployed proof refresh spec: %s\n' "$(repo_relative_path "$spec_path")" >&2
        print_validation_denominators 0 0 0 0 0
        return 1
    fi

    for section in "${REQUIRED_SECTIONS[@]}"; do
        if ! assert_required_section "$spec_path" "$section"; then
            validation_failed=1
            continue
        fi
        sections_found=$((sections_found + 1))
    done
    if ! assert_missing_capability_section "$spec_path"; then
        validation_failed=1
    else
        sections_found=$((sections_found + 1))
    fi

    while IFS= read -r invocation; do
        [ -n "$invocation" ] || continue
        commands_extracted=$((commands_extracted + 1))
        if ! verify_script_invocation "$invocation"; then
            validation_failed=1
            continue
        fi
        commands_verified=$((commands_verified + 1))
    done < <(extract_script_invocations "$spec_path")
    if [ "$commands_extracted" -eq 0 ]; then
        printf 'VACUOUS: no repo-relative scripts/ or ops/scripts/ invocations extracted from %s\n' \
            "$(repo_relative_path "$spec_path")" >&2
        validation_failed=1
    fi

    while IFS= read -r family; do
        [ -n "$family" ] || continue
        evidence_families_extracted=$((evidence_families_extracted + 1))
        if [ ! -d "$REPO_ROOT/docs/runbooks/evidence/$family" ]; then
            printf 'missing evidence family directory: docs/runbooks/evidence/%s/ in %s\n' \
                "$family" "$(repo_relative_path "$spec_path")" >&2
            validation_failed=1
            continue
        fi
        evidence_families_verified=$((evidence_families_verified + 1))
    done < <(extract_evidence_families "$spec_path")
    if [ "$evidence_families_extracted" -eq 0 ]; then
        printf 'VACUOUS: no docs/runbooks/evidence/<family>/ paths extracted from %s\n' \
            "$(repo_relative_path "$spec_path")" >&2
        validation_failed=1
    fi

    print_validation_denominators "$sections_found" "$commands_extracted" "$commands_verified" \
        "$evidence_families_extracted" "$evidence_families_verified"
    return "$validation_failed"
}

print_validation_denominators() {
    local sections_found="$1" commands_extracted="$2" commands_verified="$3"
    local evidence_families_extracted="$4" evidence_families_verified="$5"
    printf 'sections_found=%s commands_extracted=%s commands_verified=%s evidence_families_extracted=%s evidence_families_verified=%s\n' \
        "$sections_found" "$commands_extracted" "$commands_verified" \
        "$evidence_families_extracted" "$evidence_families_verified"
}

remove_required_section() {
    local source_path="$1" target_path="$2" section="$3"
    python3 - "$source_path" "$target_path" "$section" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
section = sys.argv[3]
lines = source.read_text(encoding="utf-8").splitlines()
heading_re = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
start = None
level = None

for index, line in enumerate(lines):
    match = heading_re.match(line)
    if match and match.group(2).strip("` ") == section:
        start = index
        level = len(match.group(1))
        break

if start is None:
    raise SystemExit(f"cannot mutate missing section: {section}")

end = len(lines)
for index in range(start + 1, len(lines)):
    match = heading_re.match(lines[index])
    if match and len(match.group(1)) <= level:
        end = index
        break

del lines[start:end]
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

replace_first_script_invocation() {
    local source_path="$1" target_path="$2" invocation
    invocation="$(extract_script_invocations "$source_path" | sed -n '1p')"
    if [ -z "$invocation" ]; then
        printf 'cannot mutate missing scripts/ invocation\n' >&2
        return 1
    fi
    python3 - "$source_path" "$target_path" "$invocation" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
invocation = sys.argv[3]
text = source.read_text(encoding="utf-8")
target.write_text(
    text.replace(invocation, "scripts/nonexistent_deployed_proof_probe.sh", 1),
    encoding="utf-8",
)
PY
}

run_mutation_case() {
    local specimen="$1" expected="$2" output status=0
    output="$(validate_spec "$specimen" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'mutation specimen unexpectedly passed: %s\n%s\n' "$(repo_relative_path "$specimen")" "$output" >&2
        return 1
    fi
    if [[ "$output" != *"$expected"* ]]; then
        printf 'mutation specimen missed targeted diagnostic: %s expected=%s output=%s\n' \
            "$(repo_relative_path "$specimen")" "$expected" "$output" >&2
        return 1
    fi
    printf 'PASS: mutation specimen failed as expected: %s\n' "$(basename "$specimen")"
}

run_mutation_tests() {
    local missing_section_spec bad_script_spec
    if [ ! -s "$SPEC_PATH" ]; then
        printf 'ERROR: canonical deployed proof refresh spec is absent: %s\n' "$(diagnostic_path)" >&2
        return 1
    fi

    missing_section_spec="$SCRATCH_DIR/missing_section.md"
    bad_script_spec="$SCRATCH_DIR/bad_script.md"
    remove_required_section "$SPEC_PATH" "$missing_section_spec" "${REQUIRED_SECTIONS[0]}"
    replace_first_script_invocation "$SPEC_PATH" "$bad_script_spec"

    run_mutation_case "$missing_section_spec" "missing required section: ${REQUIRED_SECTIONS[0]}"
    run_mutation_case "$bad_script_spec" \
        "direct script invocation not an executable regular file: scripts/nonexistent_deployed_proof_probe.sh"
}

write_validator_specimen() {
    local target_path="$1" extra_command="${2:-}" section
    : >"$target_path"
    for section in "${REQUIRED_SECTIONS[@]}"; do
        {
            printf '## %s\n' "$section"
            printf 'Precondition: ready\n'
            printf 'Command: bash scripts/probe_live_state.sh\n'
            printf 'Evidence path: docs/runbooks/evidence/database-recovery/\n'
            printf 'Done-condition: green\n\n'
        } >>"$target_path"
    done
    {
        printf '## MISSING CAPABILITY\nNone.\n'
        printf '%s\n' "$extra_command"
    } >>"$target_path"
}

test_validator_rejects_non_shell_script_path() {
    local specimen="$SCRATCH_DIR/non_shell_script_path.md" output status=0
    write_validator_specimen "$specimen" "Command: scripts/nonexistent_deployed_proof_probe.py"
    output="$(validate_spec "$specimen" 2>&1)" || status=$?
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"direct script invocation not an executable regular file: scripts/nonexistent_deployed_proof_probe.py"* ]]; then
        pass "validator checks repo-relative scripts paths regardless of extension"
    else
        fail "validator ignored a non-.sh scripts path. Output: $output"
    fi
}

test_validator_checks_ops_script_path() {
    local specimen="$SCRATCH_DIR/missing_ops_script.md" output status=0
    write_validator_specimen "$specimen" "Command: bash ops/scripts/nonexistent_restore_probe.sh"
    output="$(validate_spec "$specimen" 2>&1)" || status=$?
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"script invocation not readable: bash ops/scripts/nonexistent_restore_probe.sh"* ]]; then
        pass "validator checks repo-relative ops script paths"
    else
        fail "validator ignored an ops script path. Output: $output"
    fi
}

test_validator_rejects_directory_as_command() {
    local specimen="$SCRATCH_DIR/directory_command.md" output status=0
    write_validator_specimen "$specimen" "Command: scripts/tests"
    output="$(validate_spec "$specimen" 2>&1)" || status=$?
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"direct script invocation not an executable regular file: scripts/tests"* ]]; then
        pass "validator rejects directories as direct command invocations"
    else
        fail "validator accepted a directory as a command. Output: $output"
    fi
}

test_validator_rejects_script_path_traversal() {
    local outside_script="$SCRATCH_DIR/outside_probe.sh" relative_path invocation output status=0
    printf '#!/usr/bin/env bash\nexit 0\n' >"$outside_script"
    chmod +x "$outside_script"
    relative_path="$(python3 - "$REPO_ROOT/scripts" "$outside_script" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)"
    invocation="scripts/$relative_path"
    output="$(verify_script_invocation "$invocation" 2>&1)" || status=$?
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"script invocation escapes repository: $invocation"* ]]; then
        pass "validator rejects script paths that escape the repository"
    else
        fail "validator accepted a script path outside the repository. Output: $output"
    fi
}

test_validator_rejects_script_symlink_escape() {
    local original_repo_root="$REPO_ROOT" fake_repo="$SCRATCH_DIR/fake_repo"
    local outside_script="$SCRATCH_DIR/outside_symlink_probe.sh" invocation output status=0
    mkdir -p "$fake_repo/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$outside_script"
    chmod +x "$outside_script"
    ln -s "$outside_script" "$fake_repo/scripts/symlink_probe.sh"
    invocation="scripts/symlink_probe.sh"
    REPO_ROOT="$fake_repo"
    output="$(verify_script_invocation "$invocation" 2>&1)" || status=$?
    REPO_ROOT="$original_repo_root"
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"script invocation escapes repository: $invocation"* ]]; then
        pass "validator rejects in-repo symlinks that escape the repository"
    else
        fail "validator accepted a script symlink outside the repository. Output: $output"
    fi
}

test_validator_rejects_empty_required_label() {
    local specimen="$SCRATCH_DIR/empty_required_label.md" output status=0
    write_validator_specimen "$specimen"
    perl -0pi -e 's/Precondition: ready/Precondition:/' "$specimen"
    output="$(validate_spec "$specimen" 2>&1)" || status=$?
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"missing or empty label in section \"${REQUIRED_SECTIONS[0]}\": Precondition"* ]]; then
        pass "validator rejects empty required labels"
    else
        fail "validator accepted an empty required label. Output: $output"
    fi
}

test_mutation_mode_rejects_missing_canonical_spec() {
    local original_spec_path="$SPEC_PATH" output status=0
    SPEC_PATH="$SCRATCH_DIR/absent_mutation_spec.md"
    output="$(run_mutation_tests 2>&1)" || status=$?
    SPEC_PATH="$original_spec_path"
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"ERROR: canonical deployed proof refresh spec is absent:"* ]]; then
        pass "mutation mode rejects a missing canonical spec"
    else
        fail "mutation mode skipped a missing canonical spec. Output: $output"
    fi
}

test_failed_validation_prints_denominators() {
    local output status=0
    output="$(validate_spec "$SCRATCH_DIR/nonexistent_spec.md" 2>&1)" || status=$?
    if [ "$status" -ne 0 ] &&
        [[ "$output" == *"sections_found=0 commands_extracted=0 commands_verified=0 evidence_families_extracted=0 evidence_families_verified=0"* ]]; then
        pass "failed full validation prints all denominators"
    else
        fail "failed full validation omitted denominators. Output: $output"
    fi
}

test_spec_file_exists_and_is_non_empty() {
    if [ -s "$SPEC_PATH" ]; then
        pass "deployed proof refresh spec exists and is non-empty"
    else
        fail "deployed proof refresh spec exists and is non-empty (missing or empty '$(diagnostic_path)')"
    fi
}

test_spec_structure_contract() {
    local output status=0
    output="$(validate_spec "$SPEC_PATH" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        pass "deployed proof refresh spec satisfies the structure contract"
        printf '%s\n' "$output"
    else
        fail "deployed proof refresh spec satisfies the structure contract. Output: $output"
    fi
}

if [ "${1:-}" = "--mutation-test" ]; then
    run_mutation_tests
    exit 0
fi

test_spec_file_exists_and_is_non_empty
test_validator_rejects_non_shell_script_path
test_validator_checks_ops_script_path
test_validator_rejects_directory_as_command
test_validator_rejects_script_path_traversal
test_validator_rejects_script_symlink_escape
test_validator_rejects_empty_required_label
test_mutation_mode_rejects_missing_canonical_spec
test_failed_validation_prints_denominators
test_spec_structure_contract

run_test_summary
