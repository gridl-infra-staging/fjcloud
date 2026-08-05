#!/usr/bin/env bash
# merge_gate_declaration_test.sh — Contract between this repo's `[merge_validation]`
# declaration in .batman.toml and the gate names scripts/local-ci.sh can dispatch.
#
# What is being guarded. batman refuses a merge whose result fails any gate this
# repo declares (matt_root/batman/merge_validation.py::_declared_gate_tools in
# mike_dev). The declaration names gates by string. Nothing on either side of
# that string knows about the other:
#
#   * Delete the table and merges silently stop running these gates. The merge
#     still succeeds, `--fast` is unchanged, and no existing test notices — the
#     exact "a declaration that quietly no-ops is indistinguishable from no
#     declaration" failure the seam exists to end.
#   * Rename a gate in local-ci.sh and the declaration keeps naming the old one.
#     `--gate <old>` then exits 2 with "did not match any known gate", so every
#     merge is refused for a reason that has nothing to do with the branch.
#
# Both are cheap to cause and expensive to diagnose, so they are asserted here
# rather than left to the next incident. This test parses .batman.toml with the
# same tomllib batman uses, so it cannot drift from what batman will read.
#
# Anchored 2026-08-01 alongside ROADMAP "main goes red on cheap gates
# immediately after a merge, because no pre-merge gate runs them".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Emit one "<name>\t<argv...>" row per declared gate, tab-separated. Exits
# non-zero with a diagnostic on stderr when the table is absent or malformed,
# which is itself a failure of this contract.
read_declared_gates() {
    python3 - "$REPO_ROOT/.batman.toml" <<'PY'
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11 — batman falls back the same way.
    import tomli as tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)

table = data.get("merge_validation")
if not isinstance(table, dict):
    sys.exit("no [merge_validation] table in .batman.toml")
if not isinstance(table.get("budget_seconds"), (int, float)):
    sys.exit("[merge_validation].budget_seconds is missing or not a number")
gates = table.get("gates")
if not isinstance(gates, list) or not gates:
    sys.exit("[merge_validation].gates is missing or empty")

for gate in gates:
    print("\t".join([gate["name"], *gate["command"]]))
PY
}

# The declaration must exist, parse, and carry a ceiling. Without the ceiling
# one slow entry makes every merge on this host unusable.
test_declaration_is_present_and_parses() {
    local output
    if ! output="$(read_declared_gates 2>&1)"; then
        fail ".batman.toml [merge_validation] is unusable: $output"
        return
    fi
    pass ".batman.toml declares a [merge_validation] table with a budget and gates"
}

# batman builds its merge worktree with `git worktree add`, so that checkout
# contains TRACKED files only. An untracked .batman.toml is therefore absent
# from the tree the gates are read out of, and batman reads "no declaration"
# — it cannot tell that one existed. This is the one way the declaration can
# no-op with no diagnostic anywhere, so it is asserted rather than assumed.
test_declaration_is_tracked_so_it_reaches_the_merge_worktree() {
    if ! git -C "$REPO_ROOT" ls-files --error-unmatch .batman.toml >/dev/null 2>&1; then
        fail ".batman.toml is not tracked by git, so the merge worktree will not contain it and no declared gate will run"
        return
    fi
    pass ".batman.toml is tracked, so it reaches batman's merge worktree"
}

# Every declared gate must be a gate scripts/local-ci.sh actually runs, and it
# takes BOTH halves of that script's registry to be sure:
#
#   `schedule <name>`  puts the gate in SCHEDULED_GATES for `--gate <name>`.
#                      Absent, `--gate` schedules nothing and exits 2.
#   `<name>) run_gate` is the dispatch arm that runs it. The case statement has
#                      no default arm, so a scheduled gate with no arm runs
#                      nothing and the invocation still exits 0 — a merge gate
#                      that passes without executing.
#
# Requiring `schedule` also confines declarations to local-ci's parallel batch.
# The separately-scheduled tier (rust-test, web-test, rust-lint, ...) is the
# heavy one and has no business on the merge path.
test_every_declared_gate_is_dispatchable() {
    local name unscheduled=() undispatched=()
    local -a declared_names=()

    while IFS=$'\t' read -r name _rest; do
        [ -n "$name" ] || continue
        declared_names+=("$name")
        if ! grep -Eq "^schedule[[:space:]]+${name}\$" "$REPO_ROOT/scripts/local-ci.sh"; then
            unscheduled+=("$name")
        fi
        if ! grep -Eq "^[[:space:]]+${name}\)[[:space:]]+run_gate[[:space:]]" \
            "$REPO_ROOT/scripts/local-ci.sh"; then
            undispatched+=("$name")
        fi
    done < <(read_declared_gates)

    if [ "${#declared_names[@]}" -eq 0 ]; then
        fail "no declared gates were read; the parse step should have caught this"
        return
    fi
    if [ "${#unscheduled[@]}" -gt 0 ]; then
        fail "declared merge gate(s) have no 'schedule <name>' line in scripts/local-ci.sh, so --gate would schedule nothing: ${unscheduled[*]}"
    fi
    if [ "${#undispatched[@]}" -gt 0 ]; then
        fail "declared merge gate(s) have no 'run_gate' dispatch arm in scripts/local-ci.sh, so they would pass without executing: ${undispatched[*]}"
    fi
    if [ "${#unscheduled[@]}" -eq 0 ] && [ "${#undispatched[@]}" -eq 0 ]; then
        pass "all ${#declared_names[@]} declared merge gate(s) are scheduled and dispatched by local-ci.sh"
    fi
}

# The gate name and the --gate argument must agree, or the dispatchability
# assertion above checks a name the merge never actually runs.
test_declared_command_targets_its_own_gate() {
    local name rest gate_argument mismatched=()

    while IFS=$'\t' read -r name rest; do
        [ -n "$name" ] || continue
        # rest is "bash<TAB>scripts/local-ci.sh<TAB>--gate<TAB><name>"; the
        # dispatched gate is the argument after --gate.
        gate_argument="$(printf '%s' "$rest" | tr '\t' '\n' | grep -A1 -x -- '--gate' | tail -n1)"
        if [ "$gate_argument" != "$name" ]; then
            mismatched+=("$name (runs '${gate_argument:-<none>}')")
        fi
    done < <(read_declared_gates)

    if [ "${#mismatched[@]}" -gt 0 ]; then
        fail "declared gate name does not match the gate its command runs: ${mismatched[*]}"
        return
    fi
    pass "every declared gate name matches the --gate argument its command runs"
}

# Extracted so the same oracle runs against a known-bad fixture below. Without
# that self-test the arm is unfalsifiable: with local-ci.sh correct, "found no
# problems" and "checked nothing" are the same green.
report_unpropagated_failures() {
    # Gate names go in as ARGV, not on stdin: `python3 - <<'PY'` already uses
    # stdin for the script itself, so piping data in as well silently yields an
    # empty read (and a SIGPIPE that looks like a real failure).
    python3 - "$@" <<'PY'
import re, sys

source = open(sys.argv[1], encoding="utf-8").read()
declared = sys.argv[2:]

# Read the gate name -> function name mapping out of local-ci's own dispatch
# table rather than transliterating the name, so a gate whose function is named
# differently is still checked.
functions = dict(
    re.findall(r"^\s+([\w.-]+)\)\s+run_gate\s+[\w.-]+\s+(gate_\w+)", source, re.M)
)
bodies = dict(re.findall(r"^(gate_\w+)\(\)\s*\{\n(.*?)^\}", source, re.M | re.S))

problems = []
for gate in sorted(declared):
    function = functions.get(gate)
    if function is None or function not in bodies:
        problems.append(f"{gate}: no gate function found in the dispatch table")
        continue
    body = bodies[function]
    if re.search(r"^\s*set -e", body, re.M):
        continue  # `set -e` already makes every command in the body fatal
    commands = [
        line for line in body.splitlines()
        if re.match(r"^\s*(bash|python3|npx|node|make)\s", line)
    ]
    # Only non-final commands can have their status discarded; the last one is
    # the function's return value.
    for command in commands[:-1]:
        if "|| return" not in command:
            problems.append(
                f"{gate} ({function}): failure discarded -> {command.strip()}"
            )

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
}

# Self-test of the oracle above, against a fixture carrying one gate of each
# shape. This is what makes the real assertion falsifiable.
test_failure_propagation_oracle_detects_a_known_defect() {
    local fixture output
    fixture="$(mktemp)"
    cat >"$fixture" <<'FIXTURE'
gate_bad() {
    bash "$REPO_ROOT/scripts/tests/first_test.sh"
    bash "$REPO_ROOT/scripts/tests/second_test.sh"
}
gate_good() {
    bash "$REPO_ROOT/scripts/tests/first_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/second_test.sh"
}
            bad-gate) run_gate bad-gate gate_bad ;;
            good-gate) run_gate good-gate gate_good ;;
            orphan-gate) run_gate orphan-gate gate_orphan ;;
FIXTURE

    if output="$(report_unpropagated_failures "$fixture" good-gate 2>&1)"; then
        pass "propagation oracle clears a gate that guards every check"
    else
        fail "propagation oracle reported a correctly-written gate: $output"
    fi

    if output="$(report_unpropagated_failures "$fixture" bad-gate 2>&1)"; then
        fail "propagation oracle did NOT detect a gate that discards a check failure; the real assertion below is therefore meaningless"
    elif printf '%s' "$output" | grep -q 'first_test.sh'; then
        pass "propagation oracle detects a discarded check failure and names it"
    else
        fail "propagation oracle failed without naming the discarded check: $output"
    fi

    # A gate dispatched to a function that does not exist must be reported, not
    # skipped. Silently skipping it is how the oracle would stop covering a
    # gate after an unrelated refactor of local-ci.sh, with nothing to notice.
    if output="$(report_unpropagated_failures "$fixture" orphan-gate 2>&1)"; then
        fail "propagation oracle silently skipped a gate whose function is missing, so it would stop covering that gate with no diagnostic"
    else
        pass "propagation oracle reports a gate it cannot locate rather than skipping it"
    fi

    rm -f "$fixture"
}

# A declared gate that cannot report failure is worse than an undeclared one:
# it renders green on every merge while guarding nothing.
#
# The specific way that happens here is a bash footgun. A function returns the
# status of its LAST command, so a gate body like
#
#     gate_x() {
#         bash "$REPO_ROOT/scripts/tests/a_test.sh"     # <-- status discarded
#         bash "$REPO_ROOT/scripts/tests/b_test.sh"
#     }
#
# passes whenever b passes, no matter what a did. Found 2026-08-01 by chmod-ing
# scripts/api-dev.sh to 100644 in a throwaway worktree: script_exec_bits_test.sh
# exited 1 and `--gate script-exec-bits` still exited 0, so the exec-bit
# regression that gate was written for in the first place was undetectable.
#
# Neighbouring gates already use the correct form (`|| return $?`); this asserts
# it for every gate this repo declares at merge time. The class applies to all
# ~43 local-ci gates, but only the declared ones are in this file's remit.
test_declared_gates_propagate_every_check_failure() {
    local output name
    local -a declared_names=()
    while IFS=$'\t' read -r name _rest; do
        [ -n "$name" ] || continue
        declared_names+=("$name")
    done < <(read_declared_gates)

    if [ "${#declared_names[@]}" -eq 0 ]; then
        fail "no declared gates were read; the parse step should have caught this"
        return
    fi

    if ! output="$(
        report_unpropagated_failures "$REPO_ROOT/scripts/local-ci.sh" \
            "${declared_names[@]}" 2>&1
    )"; then
        fail "declared merge gate(s) cannot report a failing check:"$'\n'"$output"
        return
    fi
    pass "every declared merge gate propagates a failing check to its exit status"
}

# web-test exceeded a 600s timeout when measured on 2026-08-01 and web-lint
# needs node_modules, which the merge worktree does not have. Either one in
# this table converts every merge into a stall or a false refusal.
test_known_unrunnable_gates_are_absent() {
    local name banned=()

    while IFS=$'\t' read -r name _rest; do
        case "$name" in
            web-test|web-lint|rust-test|security-suite|test-reachability-contract)
                banned+=("$name")
                ;;
        esac
    done < <(read_declared_gates)

    if [ "${#banned[@]}" -gt 0 ]; then
        fail "gate(s) too slow or not runnable in a merge worktree are declared: ${banned[*]}"
        return
    fi
    pass "no known-unrunnable gate is declared for merge time"
}

main() {
    echo "=== merge_gate_declaration_test.sh ==="
    echo ""

    test_declaration_is_present_and_parses
    test_declaration_is_tracked_so_it_reaches_the_merge_worktree
    test_every_declared_gate_is_dispatchable
    test_declared_command_targets_its_own_gate
    test_failure_propagation_oracle_detects_a_known_defect
    test_declared_gates_propagate_every_check_failure
    test_known_unrunnable_gates_are_absent

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
