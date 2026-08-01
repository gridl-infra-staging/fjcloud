#!/usr/bin/env bash
# Red contract tests for scripts/probe_test_reachability.sh.
#
# The probe is intentionally not implemented in Stage 1. These fixture-backed
# tests define the failure and success contract it must satisfy later without
# touching the real scripts/tests/ corpus.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/probe_test_reachability.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

make_fixture() {
    local dir="$1"
    mkdir -p "$dir/scripts/tests"
    printf '# manual-only shell tests fixture\n' > "$dir/scripts/tests/manual_only_tests.txt"
    printf '# quarantined shell tests fixture\n' > "$dir/scripts/tests/quarantined_tests.txt"
    printf '# fixture roadmap\n' > "$dir/ROADMAP.md"
}

write_file() {
    local repo_root="$1" rel_path="$2" body="$3"
    mkdir -p "$(dirname "$repo_root/$rel_path")"
    printf '%s\n' "$body" > "$repo_root/$rel_path"
}

write_test() {
    local repo_root="$1" rel_path="$2" body="$3"
    write_file "$repo_root" "$rel_path" "#!/usr/bin/env bash
set -euo pipefail
$body"
    chmod +x "$repo_root/$rel_path"
}

write_local_ci() {
    local repo_root="$1" body="$2"
    write_test "$repo_root" "scripts/local-ci.sh" "REPO_ROOT=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")/..\" && pwd)\"
$body"
}

allowlist_test() {
    local repo_root="$1" rel_path="$2" reason="$3"
    printf '%s # %s\n' "$rel_path" "$reason" >> "$repo_root/scripts/tests/manual_only_tests.txt"
}

quarantine_test() {
    local repo_root="$1" rel_path="$2" reason="$3"
    printf '%s # %s\n' "$rel_path" "$reason" >> "$repo_root/scripts/tests/quarantined_tests.txt"
}

run_check() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo_root" bash "$CHECK_SCRIPT" 2>&1)" || RUN_EXIT_CODE=$?
}

test_passes_when_all_tests_are_local_ci_referenced() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_billing_contract_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_billing_contract_test.sh" 'echo reachable billing contract'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "all local-ci-referenced tests should pass reachability"
    assert_contains "$RUN_OUTPUT" "OK" "success output should be affirmative"
    assert_contains "$RUN_OUTPUT" "reachable_billing_contract_test.sh" "success output should name the reached fixture test"
    rm -rf "$tmpdir"
}

test_fails_when_orphan_test_is_not_allowlisted() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_checkout_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_checkout_test.sh" 'echo reachable checkout'
    write_test "$tmpdir" "scripts/tests/orphan_invoice_email_test.sh" 'echo orphan invoice email'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "orphan non-allowlisted tests must fail reachability"
    assert_contains "$RUN_OUTPUT" "orphan_invoice_email_test.sh" "failure must name the exact orphan test"
    assert_contains "$RUN_OUTPUT" "not reachable" "failure must explain that the test is not reachable"
    rm -rf "$tmpdir"
}

test_passes_when_orphan_test_is_allowlisted_with_reason() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_usage_rollup_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_usage_rollup_test.sh" 'echo reachable usage rollup'
    write_test "$tmpdir" "scripts/tests/orphan_manual_ops_probe_test.sh" 'echo orphan manual ops'
    allowlist_test "$tmpdir" "scripts/tests/orphan_manual_ops_probe_test.sh" "manual ops fixture is invoked by release packaging outside local-ci"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "allowlisted orphan with reason should pass reachability"
    assert_contains "$RUN_OUTPUT" "orphan_manual_ops_probe_test.sh" "success output should name the allowlisted orphan"
    assert_contains "$RUN_OUTPUT" "manual ops fixture is invoked by release packaging outside local-ci" "success output should preserve the literal allowlist reason"
    rm -rf "$tmpdir"
}

test_fails_when_allowlist_names_missing_test() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_secrets_gate_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_secrets_gate_test.sh" 'echo reachable secrets gate'
    allowlist_test "$tmpdir" "scripts/tests/missing_obsolete_probe_test.sh" "obsolete probe was intentionally retired"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "stale allowlist entries must fail reachability"
    assert_contains "$RUN_OUTPUT" "missing_obsolete_probe_test.sh" "failure must name the missing allowlisted test"
    assert_contains "$RUN_OUTPUT" "allowlist entry references missing test" "failure must explain the stale allowlist entry"
    rm -rf "$tmpdir"
}

test_fails_when_allowlist_reason_is_empty() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_doc_surface_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_doc_surface_test.sh" 'echo reachable doc surface'
    write_test "$tmpdir" "scripts/tests/orphan_empty_reason_test.sh" 'echo orphan empty reason'
    printf 'scripts/tests/orphan_empty_reason_test.sh # \n' >> "$tmpdir/scripts/tests/manual_only_tests.txt"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "empty allowlist reasons must fail reachability"
    assert_contains "$RUN_OUTPUT" "orphan_empty_reason_test.sh" "failure must name the empty-reason allowlist entry"
    assert_contains "$RUN_OUTPUT" "allowlist reason is required" "failure must explain the reason contract"
    rm -rf "$tmpdir"
}

test_fails_when_allowlist_reason_is_missing() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_missing_reason_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_missing_reason_test.sh" 'echo reachable missing-reason fixture'
    write_test "$tmpdir" "scripts/tests/orphan_missing_reason_test.sh" 'echo orphan missing reason'
    printf 'scripts/tests/orphan_missing_reason_test.sh\n' >> "$tmpdir/scripts/tests/manual_only_tests.txt"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "missing allowlist reasons must fail reachability"
    assert_contains "$RUN_OUTPUT" "orphan_missing_reason_test.sh" "failure must name the missing-reason allowlist entry"
    assert_contains "$RUN_OUTPUT" "allowlist reason is required" "failure must explain the reason contract"
    rm -rf "$tmpdir"
}

test_comment_only_root_references_are_not_reachable() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" '# bash "$REPO_ROOT/scripts/tests/shell_comment_decoy_test.sh"'
    write_file "$tmpdir" "scripts/nested/comment_decoy.py" '# scripts/tests/python_comment_decoy_test.sh'
    write_file "$tmpdir" "scripts/nested/comment_decoy.mjs" '// scripts/tests/javascript_comment_decoy_test.sh'
    write_test "$tmpdir" "scripts/tests/shell_comment_decoy_test.sh" 'echo shell comment-only decoy'
    write_test "$tmpdir" "scripts/tests/python_comment_decoy_test.sh" 'echo python comment-only decoy'
    write_test "$tmpdir" "scripts/tests/javascript_comment_decoy_test.sh" 'echo javascript comment-only decoy'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "comment-only root references must not make tests reachable"
    assert_contains "$RUN_OUTPUT" "shell_comment_decoy_test.sh" "failure must name the shell-comment decoy"
    assert_contains "$RUN_OUTPUT" "python_comment_decoy_test.sh" "failure must name the Python-comment decoy"
    assert_contains "$RUN_OUTPUT" "javascript_comment_decoy_test.sh" "failure must name the JavaScript-comment decoy"
    assert_contains "$RUN_OUTPUT" "corpus=3 reachable=0 allowlisted=0 quarantined=0 unaccounted=3" "comment decoys must preserve the exact denominator"
    rm -rf "$tmpdir"
}

test_discovers_every_root_kind_recursively() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/local_ci_root_test.sh"'
    write_file "$tmpdir" "scripts/nested/shell/root.sh" 'bash scripts/tests/nested_shell_root_test.sh'
    write_file "$tmpdir" "scripts/nested/python/root.py" 'subprocess.run(["bash", "scripts/tests/nested_python_root_test.sh"])'
    write_file "$tmpdir" "scripts/nested/javascript/root.mjs" 'execFile("bash", ["scripts/tests/nested_javascript_root_test.sh"]);'
    write_file "$tmpdir" ".github/custom/arbitrary.data" 'command: bash scripts/tests/github_arbitrary_root_test.sh'
    write_file "$tmpdir" "Makefile" $'test:\n\tbash scripts/tests/makefile_root_test.sh'
    write_test "$tmpdir" "scripts/tests/local_ci_root_test.sh" 'echo local-ci root'
    write_test "$tmpdir" "scripts/tests/nested_shell_root_test.sh" 'echo nested shell root'
    write_test "$tmpdir" "scripts/tests/nested_python_root_test.sh" 'echo nested Python root'
    write_test "$tmpdir" "scripts/tests/nested_javascript_root_test.sh" 'echo nested JavaScript root'
    write_test "$tmpdir" "scripts/tests/github_arbitrary_root_test.sh" 'echo arbitrary GitHub root'
    write_test "$tmpdir" "scripts/tests/makefile_root_test.sh" 'echo Makefile root'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "every supported recursive root kind should seed reachability"
    assert_contains "$RUN_OUTPUT" "corpus=6 reachable=6 allowlisted=0 quarantined=0 unaccounted=0" "root discovery must report exact hand-calculated counts"
    assert_contains "$RUN_OUTPUT" "nested_shell_root_test.sh" "nested shell roots must be scanned"
    assert_contains "$RUN_OUTPUT" "nested_python_root_test.sh" "nested Python roots must be scanned"
    assert_contains "$RUN_OUTPUT" "nested_javascript_root_test.sh" "nested JavaScript roots must be scanned"
    assert_contains "$RUN_OUTPUT" "github_arbitrary_root_test.sh" "arbitrary .github files must be scanned"
    assert_contains "$RUN_OUTPUT" "makefile_root_test.sh" "the root Makefile must be scanned"
    rm -rf "$tmpdir"
}

test_valid_quarantine_is_owned_counted_and_listed() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_quarantine_peer_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_quarantine_peer_test.sh" 'echo reachable quarantine peer'
    write_test "$tmpdir" "scripts/tests/owned_quarantine_alpha_test.sh" 'echo quarantined alpha'
    write_test "$tmpdir" "scripts/tests/owned_quarantine_beta_test.sh" 'echo quarantined beta'
    write_file "$tmpdir" "chats/icg/fixture_owner_lane.md" '# fixture quarantine owner'
    quarantine_test "$tmpdir" "scripts/tests/owned_quarantine_alpha_test.sh" "owned by chats/icg/fixture_owner_lane.md"
    quarantine_test "$tmpdir" "scripts/tests/owned_quarantine_beta_test.sh" "owned by chats/icg/fixture_owner_lane.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "owned quarantine entries should satisfy reachability accounting"
    assert_contains "$RUN_OUTPUT" "QUARANTINED: scripts/tests/owned_quarantine_alpha_test.sh # owned by chats/icg/fixture_owner_lane.md" "the full first quarantine entry must be listed"
    assert_contains "$RUN_OUTPUT" "QUARANTINED: scripts/tests/owned_quarantine_beta_test.sh # owned by chats/icg/fixture_owner_lane.md" "the full second quarantine entry must be listed"
    assert_contains "$RUN_OUTPUT" "corpus=3 reachable=1 allowlisted=0 quarantined=2 unaccounted=0" "quarantine counts must use the discovered corpus"
    rm -rf "$tmpdir"
}

test_fails_when_reachable_test_is_also_quarantined() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/dual_classified_test.sh"'
    write_test "$tmpdir" "scripts/tests/dual_classified_test.sh" 'echo dual classified'
    quarantine_test "$tmpdir" "scripts/tests/dual_classified_test.sh" "owned by ROADMAP.md:1"
    printf '| P1 | Fixture owner | probe fixture |\n' > "$tmpdir/ROADMAP.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "reachable tests must not also remain quarantined"
    assert_contains "$RUN_OUTPUT" "reachable test cannot also be quarantined: scripts/tests/dual_classified_test.sh" \
        "overlap output must name the conflicting quarantined test"
    rm -rf "$tmpdir"
}

test_reports_all_quarantine_registry_defects() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_registry_peer_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_registry_peer_test.sh" 'echo reachable registry peer'
    write_test "$tmpdir" "scripts/tests/missing_reason_quarantine_test.sh" 'echo missing reason'
    write_test "$tmpdir" "scripts/tests/ownerless_quarantine_test.sh" 'echo ownerless quarantine'
    write_file "$tmpdir" "chats/icg/fixture_owner_lane.md" '# fixture quarantine owner'
    quarantine_test "$tmpdir" "scripts/tests/missing_quarantine_target_test.sh" "owned by chats/icg/fixture_owner_lane.md"
    printf 'scripts/tests/missing_reason_quarantine_test.sh\n' >> "$tmpdir/scripts/tests/quarantined_tests.txt"
    quarantine_test "$tmpdir" "scripts/tests/ownerless_quarantine_test.sh" "known failure awaiting triage"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "all quarantine registry defects must make the verdict fail"
    assert_contains "$RUN_OUTPUT" "missing_quarantine_target_test.sh" "stale quarantine output must name the missing corpus file"
    assert_contains "$RUN_OUTPUT" "quarantine entry references missing test" "stale quarantine output must explain the defect"
    assert_contains "$RUN_OUTPUT" "missing_reason_quarantine_test.sh" "malformed quarantine output must name the row"
    assert_contains "$RUN_OUTPUT" "quarantine reason is required" "malformed quarantine output must explain the missing reason"
    assert_contains "$RUN_OUTPUT" "ownerless_quarantine_test.sh" "ownerless quarantine output must name the row"
    assert_contains "$RUN_OUTPUT" "quarantine owner is required" "ownerless quarantine output must explain the owner contract"
    rm -rf "$tmpdir"
}

test_rejects_quarantine_owners_outside_repo_root() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_external_owner_peer_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_external_owner_peer_test.sh" 'echo reachable external-owner peer'
    write_test "$tmpdir" "scripts/tests/external_owner_test.sh" 'echo external owner'
    write_file "$tmpdir" "../outside-owner.md" '# outside owner'
    quarantine_test "$tmpdir" "scripts/tests/external_owner_test.sh" "owned by ../outside-owner.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "quarantine owners must stay inside the repo root"
    assert_contains "$RUN_OUTPUT" "external_owner_test.sh" "traversal output must name the quarantined test"
    assert_contains "$RUN_OUTPUT" "quarantine owner is required" "traversal output must reject outside-repo owners"
    rm -f "$tmpdir/../outside-owner.md"
    rm -rf "$tmpdir"
}

test_reports_multiple_unaccounted_tests_and_all_five_counts() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/reachable_summary_test.sh"'
    write_test "$tmpdir" "scripts/tests/reachable_summary_test.sh" 'echo reachable summary'
    write_test "$tmpdir" "scripts/tests/manual_summary_test.sh" 'echo manual summary'
    write_test "$tmpdir" "scripts/tests/quarantine_summary_test.sh" 'echo quarantine summary'
    write_test "$tmpdir" "scripts/tests/unaccounted_alpha_test.sh" 'echo unaccounted alpha'
    write_test "$tmpdir" "scripts/tests/unaccounted_beta_test.sh" 'echo unaccounted beta'
    write_file "$tmpdir" "chats/icg/fixture_owner_lane.md" '# fixture quarantine owner'
    allowlist_test "$tmpdir" "scripts/tests/manual_summary_test.sh" "requires a deployed staging fixture"
    quarantine_test "$tmpdir" "scripts/tests/quarantine_summary_test.sh" "owned by chats/icg/fixture_owner_lane.md"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "multiple simultaneous unaccounted tests must fail together"
    assert_contains "$RUN_OUTPUT" "not reachable: scripts/tests/unaccounted_alpha_test.sh" "the first unaccounted test must be reported"
    assert_contains "$RUN_OUTPUT" "not reachable: scripts/tests/unaccounted_beta_test.sh" "the second unaccounted test must be reported"
    assert_contains "$RUN_OUTPUT" "corpus=5 reachable=1 allowlisted=1 quarantined=1 unaccounted=2" "all five summary counts must match the hand-calculated fixture"
    rm -rf "$tmpdir"
}

test_zero_corpus_is_vacuous_not_ok() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'echo no corpus'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "a zero-file corpus must fail closed"
    assert_contains "$RUN_OUTPUT" "VACUOUS" "zero corpus output must use the explicit VACUOUS label"
    assert_contains "$RUN_OUTPUT" "corpus=0 reachable=0 allowlisted=0 quarantined=0 unaccounted=0" "zero corpus output must still include all five counts"
    rm -rf "$tmpdir"
}

test_passes_with_transitive_test_reachability() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_local_ci "$tmpdir" 'bash "$REPO_ROOT/scripts/tests/transitive_entry_test.sh"'
    write_test "$tmpdir" "scripts/tests/transitive_entry_test.sh" 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/transitive_helper_test.sh"'
    write_test "$tmpdir" "scripts/tests/transitive_helper_test.sh" 'echo transitive helper reached'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "local-ci-to-test-to-test reachability should pass"
    assert_contains "$RUN_OUTPUT" "transitive_entry_test.sh" "success output should name the direct test"
    assert_contains "$RUN_OUTPUT" "transitive_helper_test.sh" "success output should name the transitive test"
    rm -rf "$tmpdir"
}

test_local_ci_registration_is_complete() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local manifest="$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"
    local gate_name="test-reachability-contract"
    local gate_body runner_body

    assert_file_exists "$manifest" \
        "classified hermetic reachability tests have a canonical manifest"
    assert_eq \
        "$(grep -Fxc '    "scripts/tests/algolia_import_dispatch_live_probe_test.sh"' "$manifest" || true)" \
        "1" \
        "the repaired Algolia dispatch probe is registered exactly once"
    assert_eq \
        "$(grep -Fxc '    "scripts/tests/catalog_lifecycle_service_window_live_probe_test.sh"' "$manifest" || true)" \
        "1" \
        "the repaired catalog lifecycle service-window probe is registered exactly once"
    assert_eq \
        "$(grep -Fxc '    "scripts/tests/gitleaks_allowlist_contract_test.sh"' "$manifest" || true)" \
        "1" \
        "the gitleaks allowlist contract is registered exactly once"
    assert_eq \
        "$(grep -Fxc '    "scripts/tests/chaos_ha_failover_proof_test.sh"' "$manifest" || true)" \
        "1" \
        "focused HA failover proof suite runs exactly once through the hermetic manifest"
    assert_eq \
        "$(grep -Fxc '    "scripts/tests/chaos_test.sh"' "$manifest" || true)" \
        "0" \
        "aggregate chaos suite is absent so it cannot duplicate the focused HA execution"
    assert_eq \
        "$(grep -Fxc '#                    test-reachability-contract,' "$local_ci" || true)" \
        "1" \
        "local-ci usage help names the reachability gate exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_test_reachability_contract() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines the reachability gate exactly once"
    assert_eq \
        "$(grep -Fxc 'schedule test-reachability-contract' "$local_ci" || true)" \
        "0" \
        "local-ci fast scheduler keeps the reachability gate out of the parallel batch"
    assert_eq \
        "$(grep -Fxc 'if [ -z "$SINGLE_GATE" ] || [ "$SINGLE_GATE" = "test-reachability-contract" ]; then' "$local_ci" || true)" \
        "1" \
        "local-ci sequential selector names the reachability gate exactly once"
    assert_eq \
        "$(grep -Fxc '            test-reachability-contract) run_gate test-reachability-contract gate_test_reachability_contract ;;' "$local_ci" || true)" \
        "0" \
        "local-ci has no parallel dispatch arm for the reachability gate"
    assert_eq \
        "$(grep -Fxc '    run_gate test-reachability-contract gate_test_reachability_contract' "$local_ci" || true)" \
        "1" \
        "local-ci runs the reachability gate exactly once in the sequential tail"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci summary-only inventory names the reachability gate exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci unknown-gate help names the reachability gate exactly once"
    gate_body="$(sed -n '/^gate_test_reachability_contract()/,/^}/p' "$local_ci")"
    assert_contains "$gate_body" 'source "$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"' \
        "reachability gate loads the canonical hermetic test manifest"
    # These three replace a single assertion that matched the literal serial
    # line `bash "$REPO_ROOT/$test_path" || return $?`. That pinned an
    # implementation detail, not the contract, and blocked running the manifest
    # concurrently. What actually has to hold is: every manifest entry is
    # iterated, every entry is executed, and no entry's exit code is discarded.
    # The third is the one that matters under concurrency, where the classic bug
    # is backgrounding jobs and losing their statuses.
    assert_contains "$gate_body" '"${TEST_REACHABILITY_HERMETIC_TESTS[@]}"' \
        "reachability gate iterates every entry in the canonical manifest"
    assert_contains "$gate_body" 'run_reachability_suite "$test_path" "$results_dir"' \
        "reachability gate sends every classified hermetic test through its suite runner"
    runner_body="$(sed -n '/^run_reachability_suite()/,/^}/p' "$local_ci")"
    assert_contains "$runner_body" 'bash "$REPO_ROOT/$test_path"' \
        "reachability gate executes every classified hermetic test"
    assert_contains "$gate_body" 'failed+=' \
        "reachability gate records each failing suite rather than discarding its status"
    assert_contains "$gate_body" 'return 1' \
        "reachability gate fails when any hermetic suite fails"

    # The serial registry is a scheduling list, not a skip list. Its entries are
    # excluded from the concurrent batch and then run sequentially; if that tail
    # were ever dropped, those suites would silently stop running, which is the
    # exact defect this gate exists to catch.
    assert_contains "$gate_body" 'serial_only_tests.txt' \
        "reachability gate consults the serial-only registry"
    assert_contains "$gate_body" 'serial registry names a test not in the hermetic manifest' \
        "reachability gate rejects a serial entry that is not in the manifest"

    local serial_registry serial_entry manifest
    serial_registry="$REPO_ROOT/scripts/tests/serial_only_tests.txt"
    assert_eq "$([ -f "$serial_registry" ] && echo present || echo missing)" "present" \
        "the serial-only registry exists"
    assert_eq \
        "$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$serial_registry" \
            | grep -Fxc 'scripts/tests/run_browser_lane_against_staging_test.sh' || true)" \
        "0" \
        "duplicate-green browser-lane contract should not remain in the serial tail"
    assert_eq \
        "$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$serial_registry" \
            | grep -Fxc 'scripts/tests/seed_synthetic_traffic_test.sh' || true)" \
        "0" \
        "duplicate-green synthetic traffic contract should not remain in the serial tail"
    assert_eq \
        "$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$serial_registry" \
            | grep -Fxc 'scripts/tests/api_dev_test.sh' || true)" \
        "0" \
        "duplicate-green api-dev contract should not remain in the serial tail"
    manifest="$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"
    while IFS= read -r serial_entry; do
        [ -n "$serial_entry" ] || continue
        assert_eq "$(grep -Fc "\"$serial_entry\"" "$manifest" || true)" "1" \
            "serial-only entry $serial_entry is still in the hermetic manifest and therefore still runs"
    done <<SERIAL_EOF
$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$serial_registry")
SERIAL_EOF
    assert_contains "$gate_body" 'scripts/tests/probe_test_reachability_test.sh' \
        "reachability gate runs the hermetic contract suite"
    assert_contains "$gate_body" 'scripts/probe_test_reachability.sh' \
        "reachability gate audits the real corpus"
}

test_passes_when_all_tests_are_local_ci_referenced
test_fails_when_orphan_test_is_not_allowlisted
test_passes_when_orphan_test_is_allowlisted_with_reason
test_fails_when_allowlist_names_missing_test
test_fails_when_allowlist_reason_is_empty
test_fails_when_allowlist_reason_is_missing
test_comment_only_root_references_are_not_reachable
test_discovers_every_root_kind_recursively
test_valid_quarantine_is_owned_counted_and_listed
test_fails_when_reachable_test_is_also_quarantined
test_reports_all_quarantine_registry_defects
test_rejects_quarantine_owners_outside_repo_root
test_reports_multiple_unaccounted_tests_and_all_five_counts
test_zero_corpus_is_vacuous_not_ok
test_passes_with_transitive_test_reachability
test_local_ci_registration_is_complete

run_test_summary
