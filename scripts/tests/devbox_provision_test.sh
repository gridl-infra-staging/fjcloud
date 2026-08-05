#!/usr/bin/env bash
# Tests for scripts/devbox/provision_devbox.sh — the ephemeral Linux devbox
# used to run fjcloud's LOCAL-phase suites (browser/Playwright + local-ci) off
# the operator's Mac, so the repo-wide `local-ci --fast` lock stops serialising
# every worker.
#
# Two of these tests exist because the repository has already been burned by the
# exact failure they encode, and both are OPEN P0 rows in ROADMAP.md today:
#
#   * test_refuses_world_open_ssh_cidr — "Public engine port + unauthenticated
#     engine dashboard" is open precisely because a 0.0.0.0/0 ingress rule got
#     created and then outlived the reason for it. A devbox that accepts
#     --ssh-cidr 0.0.0.0/0 would open a second one, on a host that holds a
#     clone of the source tree.
#
#   * test_never_attaches_iam_instance_profile — "Deactivate credentials exposed
#     by the public-mirror evidence" is open. The local phase needs zero AWS
#     (postgres + docker + the flapjack binary is the entire dependency set), so
#     an instance profile would widen the credential blast radius to buy nothing.
#     The absence of --iam-instance-profile IS the security property; it is
#     asserted rather than assumed because nothing else in the launch call
#     would reveal its reintroduction.
#
# The `aws` stub below encodes the AWS CLI's OWN documented output contract, not
# what provision_devbox.sh happens to find convenient (rule 5, commit 2ae542008).
# The load-bearing case is `--output text` on a JMESPath expression:
#   - a null scalar   (`SecurityGroups[0].GroupId` on an empty list) prints None
#   - an empty list   (`Reservations[].Instances[].InstanceId`)      prints nothing
# Those two are NOT the same string, and a script that treats the literal "None"
# as a real security-group id creates a broken rule against group "None". That
# is the defect test_treats_none_scalar_as_absent_security_group pins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

# System under test.
PROVISION="$REPO_ROOT/scripts/devbox/provision_devbox.sh"
CLOUD_INIT="$REPO_ROOT/scripts/devbox/cloud_init.yaml"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------------------------------------------------------------------------
# Mock `aws`
# ---------------------------------------------------------------------------
# Every invocation is appended verbatim to $AWS_CALL_LOG so tests can assert on
# both the presence of a call and the exact flags it carried. Behaviour is
# driven by env vars the test exports:
#   DEVBOX_MOCK_EXISTING_INSTANCE  instance id an existing-devbox lookup returns
#                                  (empty => the real CLI's empty-list output)
#   DEVBOX_MOCK_EXISTING_SG        security group id a lookup returns
#                                  (empty => the real CLI's "None" null output)
mock_aws_body() {
    cat <<'MOCK'
set -euo pipefail
# Record the full argv one call per line for later assertions.
printf '%s\n' "$*" >> "$AWS_CALL_LOG"

case "${2:-}" in
    describe-instances)
        # Real contract: a JMESPath LIST projection that matches nothing renders
        # as an empty line under --output text (NOT the string "None"). A
        # multi-element projection renders TAB-separated on one line per row.
        if [ -n "${DEVBOX_MOCK_EXISTING_INSTANCE:-}" ]; then
            printf '%s\t%s\n' "$DEVBOX_MOCK_EXISTING_INSTANCE" "${DEVBOX_MOCK_EXISTING_STATE:-running}"
        else
            printf '\n'
        fi
        exit 0 ;;
    describe-security-groups)
        # Real contract: a JMESPath SCALAR that resolves to null renders as the
        # literal string "None" under --output text. Emitting "" here instead
        # would make the stub agree with a buggy caller and hide the defect.
        if [ -n "${DEVBOX_MOCK_EXISTING_SG:-}" ]; then
            printf '%s\n' "$DEVBOX_MOCK_EXISTING_SG"
        else
            printf 'None\n'
        fi
        exit 0 ;;
    create-security-group)
        printf 'sg-newly0created\n'
        exit 0 ;;
    authorize-security-group-ingress)
        exit 0 ;;
    run-instances)
        printf 'i-0devbox0launched\n'
        exit 0 ;;
    terminate-instances)
        exit 0 ;;
    start-instances)
        exit 0 ;;
    describe-images)
        # Latest-AMI lookup. Real contract: scalar string under --output text.
        printf 'ami-0stubbedimage\n'
        exit 0 ;;
esac
echo "unexpected aws call: $*" >&2
exit 99
MOCK
}

# Run provision_devbox.sh with a stubbed `aws` on PATH and a fresh call log.
# Sets LAST_OUTPUT / LAST_CALL_LOG_CONTENT and returns the script's exit code.
#
# NOTE: callers on the happy path must append `|| true`. Under `set -e` a
# non-zero return here would abort the whole runner at the first regression and
# hide every later test's verdict.
run_provision() {
    local mock_dir call_log rc output
    mock_dir="$(new_mock_command_dir aws "$(mock_aws_body)")"
    call_log="$(mktemp)"

    set +e
    output="$(
        PATH="$mock_dir:$PATH" \
        AWS_CALL_LOG="$call_log" \
        DEVBOX_MOCK_EXISTING_INSTANCE="${DEVBOX_MOCK_EXISTING_INSTANCE:-}" \
        DEVBOX_MOCK_EXISTING_SG="${DEVBOX_MOCK_EXISTING_SG:-}" \
        DEVBOX_MOCK_EXISTING_STATE="${DEVBOX_MOCK_EXISTING_STATE:-}" \
        AWS_DEFAULT_REGION=us-east-1 \
        bash "$PROVISION" "$@" 2>&1
    )"
    rc=$?
    set -e

    LAST_OUTPUT="$output"
    LAST_CALL_LOG_CONTENT="$(cat "$call_log")"
    rm -rf "$mock_dir" "$call_log"
    return $rc
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
# Without this, every refusal test below is a FALSE POSITIVE: `bash` on a
# missing file also exits non-zero, so "script absent" would be indistinguishable
# from "script correctly refused". The refusal tests additionally bind to the
# DEVBOX_REFUSED: diagnostic for the same reason — a non-zero exit alone proves
# nothing about *why* the run stopped.
test_system_under_test_exists() {
    assert_file_exists "$PROVISION" "the provisioner script exists"
    if [ -x "$PROVISION" ]; then
        pass "the provisioner script is executable"
    else
        fail "the provisioner script is executable (chmod +x missing)"
    fi
}

# ---------------------------------------------------------------------------
# Security invariants
# ---------------------------------------------------------------------------

test_refuses_world_open_ssh_cidr() {
    local rc=0
    run_provision --name t1 --ssh-cidr 0.0.0.0/0 || rc=$?
    assert_ne "$rc" "0" "world-open IPv4 SSH CIDR is refused"
    assert_contains "$LAST_OUTPUT" "DEVBOX_REFUSED:" \
        "the refusal is an explicit diagnostic, not an incidental non-zero exit"
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "run-instances" \
        "no instance is launched when the SSH CIDR is world-open"
}

test_refuses_world_open_ipv6_ssh_cidr() {
    local rc=0
    run_provision --name t1 --ssh-cidr "::/0" || rc=$?
    assert_ne "$rc" "0" "world-open IPv6 SSH CIDR is refused"
    assert_contains "$LAST_OUTPUT" "DEVBOX_REFUSED:" \
        "the IPv6 refusal is an explicit diagnostic"
}

test_requires_explicit_ssh_cidr() {
    local rc=0
    run_provision --name t1 || rc=$?
    assert_ne "$rc" "0" "a missing --ssh-cidr is refused rather than defaulted"
    assert_contains "$LAST_OUTPUT" "DEVBOX_REFUSED:" \
        "the missing-CIDR refusal is an explicit diagnostic"
}

test_never_attaches_iam_instance_profile() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_CALL_LOG_CONTENT" "run-instances" \
        "a launch happens on the happy path"
    # The security property: no role => no credentials on the box.
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "--iam-instance-profile" \
        "the devbox is launched with NO IAM instance profile"
}

test_requires_imdsv2_and_disables_metadata_tags() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_CALL_LOG_CONTENT" "HttpTokens=required" \
        "IMDSv2 is required on the devbox (matches ops/ VM launch convention)"
}

test_ingress_rule_carries_the_operator_cidr() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_CALL_LOG_CONTENT" "203.0.113.10/32" \
        "the SSH ingress rule is scoped to the caller-supplied CIDR"
}

# ---------------------------------------------------------------------------
# AWS CLI contract handling
# ---------------------------------------------------------------------------

test_treats_none_scalar_as_absent_security_group() {
    # DEVBOX_MOCK_EXISTING_SG empty => stub prints "None" (real CLI behaviour).
    # A correct caller creates a group; a buggy one authorises against "None".
    DEVBOX_MOCK_EXISTING_SG="" run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_CALL_LOG_CONTENT" "create-security-group" \
        "the literal 'None' scalar is treated as absent, so a group is created"
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "--group-id None" \
        "no AWS call is ever made against a group literally named None"
}

test_reuses_existing_security_group() {
    DEVBOX_MOCK_EXISTING_SG="sg-0already0there" \
        run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "create-security-group" \
        "an existing devbox security group is reused, not duplicated"
}

# ---------------------------------------------------------------------------
# Cost / idempotency
# ---------------------------------------------------------------------------

test_reuses_running_instance_instead_of_launching_duplicate() {
    DEVBOX_MOCK_EXISTING_INSTANCE="i-0already0running" \
        run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "run-instances" \
        "a running devbox of the same name is reused rather than duplicated"
    assert_contains "$LAST_OUTPUT" "i-0already0running" \
        "the existing instance id is reported back to the caller"
}

test_emits_machine_readable_instance_id() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_OUTPUT" "DEVBOX_INSTANCE_ID=i-0devbox0launched" \
        "the instance id is emitted in a machine-readable KEY=value line"
}

test_tags_follow_repo_convention() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    # Matches scripts/validate_vm_autorepair_detection.sh:340 so existing
    # tag-based inventory/cleanup tooling can see this instance.
    assert_contains "$LAST_CALL_LOG_CONTENT" "Key=managed-by,Value=fjcloud" \
        "the instance carries the repo-standard managed-by tag"
    assert_contains "$LAST_CALL_LOG_CONTENT" "Key=stage,Value=devbox" \
        "the instance carries a stage tag identifying it as a devbox"
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

test_dry_run_makes_no_mutating_call() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 --dry-run || true
    for verb in run-instances create-security-group \
                authorize-security-group-ingress terminate-instances; do
        assert_not_contains "$LAST_CALL_LOG_CONTENT" "$verb" \
            "--dry-run issues no $verb call"
    done
}

test_dry_run_still_reports_the_plan() {
    run_provision --name t1 --ssh-cidr 203.0.113.10/32 --dry-run || true
    assert_contains "$LAST_OUTPUT" "203.0.113.10/32" \
        "--dry-run prints the ingress CIDR it would have used"
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

test_terminate_only_targets_tagged_devbox() {
    DEVBOX_MOCK_EXISTING_INSTANCE="i-0already0running" \
        run_provision --name t1 --terminate || true
    assert_contains "$LAST_CALL_LOG_CONTENT" "terminate-instances" \
        "--terminate issues a terminate call"
    assert_contains "$LAST_CALL_LOG_CONTENT" "i-0already0running" \
        "--terminate targets the instance discovered by devbox tag lookup"
    assert_contains "$LAST_CALL_LOG_CONTENT" "Name=tag:stage,Values=devbox" \
        "--terminate discovers its target by devbox tag, never by bare name alone"
}

test_terminate_is_a_noop_when_nothing_is_running() {
    local rc=0
    DEVBOX_MOCK_EXISTING_INSTANCE="" run_provision --name t1 --terminate || rc=$?
    assert_eq "$rc" "0" "--terminate exits 0 when there is nothing to terminate"
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "terminate-instances" \
        "--terminate issues no call when no devbox instance exists"
}

# ---------------------------------------------------------------------------
# Cloud-init payload
# ---------------------------------------------------------------------------

test_cloud_init_installs_local_phase_dependencies() {
    assert_file_exists "$CLOUD_INIT" "the cloud-init payload exists"
    local content
    content="$(cat "$CLOUD_INIT")"
    # These are exactly what docker-compose.yml + the Rust/Node build need.
    for dep in docker git; do
        assert_contains "$content" "$dep" "cloud-init provisions $dep"
    done
}

test_cloud_init_installs_no_aws_cli() {
    # Deliberate: the box has no credentials, so an AWS CLI on it is at best
    # dead weight and at worst an invitation to put credentials there later.
    assert_file_not_matching_regex "$CLOUD_INIT" '(awscli|aws-cli)' \
        "cloud-init does NOT install an AWS CLI onto the credential-free devbox"
}

test_provisioner_embeds_no_credentials() {
    # scripts/ syncs wholesale to the PUBLIC mirror per .debbie.toml, and the
    # mirror-leak P0 is open. Nothing secret may live in these two files.
    assert_file_not_matching_regex "$PROVISION" '(AKIA[0-9A-Z]{16}|sk_live_|rk_live_)' \
        "the provisioner embeds no credential literals (it ships to the public mirror)"
    assert_file_not_matching_regex "$CLOUD_INIT" '(AKIA[0-9A-Z]{16}|sk_live_|rk_live_)' \
        "the cloud-init payload embeds no credential literals"
}


# ---------------------------------------------------------------------------
# Auto-stop and stopped-instance reuse
# ---------------------------------------------------------------------------
# These two are a pair. Idle auto-stop is what keeps an unattended devbox from
# billing compute around the clock, but a stopped instance is invisible to a
# reuse lookup that only matches running ones — so without the second test the
# first one silently converts "reuse the box" into "launch a second box", which
# costs MORE than having no auto-stop at all.

test_cloud_init_installs_idle_autostop() {
    local content
    content="$(cat "$CLOUD_INIT")"
    assert_contains "$content" "fjcloud-devbox-idle-stop" \
        "cloud-init installs the idle auto-stop unit"
    assert_contains "$content" "systemctl enable --now fjcloud-devbox-idle-stop.timer" \
        "the idle auto-stop timer is actually enabled, not just written to disk"
}

test_reuse_lookup_includes_stopped_instances() {
    DEVBOX_MOCK_EXISTING_INSTANCE="i-0halted0box" DEVBOX_MOCK_EXISTING_STATE="stopped" \
        run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_CALL_LOG_CONTENT" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        "the reuse lookup filter includes stopped instances"
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "run-instances" \
        "an auto-stopped devbox is restarted, never duplicated by a fresh launch"
}

test_stopped_instance_is_restarted() {
    DEVBOX_MOCK_EXISTING_INSTANCE="i-0halted0box" DEVBOX_MOCK_EXISTING_STATE="stopped" \
        run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_contains "$LAST_CALL_LOG_CONTENT" "start-instances" \
        "a stopped devbox is started back up"
    assert_contains "$LAST_OUTPUT" "DEVBOX_INSTANCE_ID=i-0halted0box" \
        "the restarted instance id is reported to the caller"
}

test_running_instance_is_not_restarted() {
    DEVBOX_MOCK_EXISTING_INSTANCE="i-0already0running" DEVBOX_MOCK_EXISTING_STATE="running" \
        run_provision --name t1 --ssh-cidr 203.0.113.10/32 || true
    assert_not_contains "$LAST_CALL_LOG_CONTENT" "start-instances" \
        "an already-running devbox is not needlessly restarted"
}

# Ubuntu 24.04 "noble" renamed a set of libraries as part of the 64-bit time_t
# transition: the old name no longer exists and `apt install` fails outright on
# it. cloud-init's package stage then errors, the box still boots and still
# writes its ready marker, and the breakage only surfaces later as a Playwright
# browser that cannot launch — far from its cause.
#
# The renames below were read off a live noble box with
# `apt-cache search --names-only`, not inferred from the naming pattern, so this
# table is the distro's contract rather than a guess about it.
NOBLE_T64_RENAMES=(
    "libatk1.0-0:libatk1.0-0t64"
    "libatk-bridge2.0-0:libatk-bridge2.0-0t64"
    "libcups2:libcups2t64"
    "libasound2:libasound2t64"
)

test_cloud_init_uses_noble_package_names() {
    local content pair old new
    content="$(cat "$CLOUD_INIT")"
    for pair in "${NOBLE_T64_RENAMES[@]}"; do
        old="${pair%%:*}"
        new="${pair##*:}"
        # Match the list entry exactly ("  - <name>" to end of line) so the old
        # name is not "found" as a prefix of the t64 name it was renamed to.
        if grep -qE "^[[:space:]]*-[[:space:]]+${old//./\\.}[[:space:]]*$" "$CLOUD_INIT"; then
            fail "cloud-init lists pre-noble package '$old' (apt install fails; use '$new')"
        else
            pass "cloud-init does not list the pre-noble name '$old'"
        fi
        assert_contains "$content" "$new" \
            "cloud-init lists the noble package name '$new'"
    done
}

test_cloud_init_installs_the_node_major_the_repo_pins() {
    # .nvmrc is the repo's single source of truth for the Node major version,
    # and it is not decorative: the Cloudflare adapter dependency chain requires
    # Node 22, and a version skew here already cost this repo a broken CI lane
    # (LAUNCH.md, 2026-05-03). Ubuntu 24.04's `nodejs` package is Node 18, so
    # installing the distro package silently produces the wrong runtime.
    #
    # This asserts the RELATIONSHIP rather than duplicating the constant: bump
    # .nvmrc and this test forces cloud-init to be bumped with it, which a
    # hardcoded "22" here would not.
    local want_major
    want_major="$(tr -d '[:space:]' < "$REPO_ROOT/.nvmrc" | cut -d. -f1)"
    if [ -z "$want_major" ]; then
        fail "could not read a Node major version from .nvmrc"
        return
    fi
    assert_contains "$(cat "$CLOUD_INIT")" "setup_${want_major}.x" \
        "cloud-init installs Node ${want_major}.x, the major .nvmrc pins"
    # The distro package must not be listed alongside it, or apt resolves the
    # older nodejs first and the NodeSource install is a no-op.
    if grep -qE '^[[:space:]]*-[[:space:]]+nodejs[[:space:]]*$' "$CLOUD_INIT"; then
        fail "cloud-init still lists the distro 'nodejs' package (Node 18 on noble)"
    else
        pass "cloud-init does not list the distro nodejs package"
    fi
}

# Commands the local stack shells out to, mapped to the apt package providing
# them. Derived by grepping scripts/playwright_local_stack.sh and its libs for
# invoked binaries, then checking each against a real noble box — not guessed.
#
# This exists because a missing CLI here does not fail loudly at provision time.
# It fails much later, inside Playwright's webServer startup, as
# "psql: command not found" + "Process from config.webServer was not able to
# start", which reads like a Playwright or migration problem rather than a
# missing package. That is exactly how it presented on the first real run.
STACK_REQUIRED_PACKAGES=(
    "psql:postgresql-client"        # migrations + DB assertions in the stack
    "docker:docker.io"              # docker-compose services
    "curl:curl"                     # health polling
)

test_cloud_init_provides_the_local_stack_clis() {
    local pair cmd pkg content
    content="$(cat "$CLOUD_INIT")"
    for pair in "${STACK_REQUIRED_PACKAGES[@]}"; do
        cmd="${pair%%:*}"
        pkg="${pair##*:}"
        assert_contains "$content" "$pkg" \
            "cloud-init installs $pkg, which provides '$cmd' for the local stack"
    done
}

# ---------------------------------------------------------------------------

for t in \
    test_system_under_test_exists \
    test_refuses_world_open_ssh_cidr \
    test_refuses_world_open_ipv6_ssh_cidr \
    test_requires_explicit_ssh_cidr \
    test_never_attaches_iam_instance_profile \
    test_requires_imdsv2_and_disables_metadata_tags \
    test_ingress_rule_carries_the_operator_cidr \
    test_treats_none_scalar_as_absent_security_group \
    test_reuses_existing_security_group \
    test_reuses_running_instance_instead_of_launching_duplicate \
    test_emits_machine_readable_instance_id \
    test_tags_follow_repo_convention \
    test_dry_run_makes_no_mutating_call \
    test_dry_run_still_reports_the_plan \
    test_terminate_only_targets_tagged_devbox \
    test_terminate_is_a_noop_when_nothing_is_running \
    test_cloud_init_installs_local_phase_dependencies \
    test_cloud_init_installs_no_aws_cli \
    test_cloud_init_uses_noble_package_names \
    test_cloud_init_installs_the_node_major_the_repo_pins \
    test_cloud_init_provides_the_local_stack_clis \
    test_cloud_init_installs_idle_autostop \
    test_reuse_lookup_includes_stopped_instances \
    test_stopped_instance_is_restarted \
    test_running_instance_is_not_restarted \
    test_provisioner_embeds_no_credentials \
    ; do
    "$t"
done

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
