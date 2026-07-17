#!/usr/bin/env bash
# Contract tests for scripts/launch/apply_ses_log_read_policy.sh — the guarded
# rollout CLI for the SES send-events CloudWatch Logs read policy.
#
# Design: every external side-effect is an injected fake. `aws`, `terraform` are
# shadowed on PATH; the on-host SSM shell is injected via APPLY_SES_SSM_EXEC. Each
# case configures the fakes through FAKE_* env vars, runs the script against a
# throwaway repo-relative artifact dir, then asserts the terminal status and the
# recorded summary.json facts.
#
# Terraform stays the single source of truth for policy shape: the happy-path live
# policy fixture is DERIVED from ops/iam/fjcloud-instance-role.tf by the same
# normalizer the script uses, so a drift in the checked-in owner is caught here
# rather than papered over by a second hand-maintained JSON.
#
# Group-1 (tests-first) exit condition: with the script absent every case fails
# only for the "script_missing" reason (run_apply short-circuits to that status),
# so the red is unambiguous and free of test-harness bugs.
#
# PATH/env are deliberately mutated inside per-case subshells so each case runs
# against its own fakes in isolation; that locality is the intent, not a bug.
# RUN_RC captures each run's exit code for diagnostics even when no case asserts on it.
# shellcheck disable=SC1091,SC2030,SC2031,SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

SUT="$REPO_ROOT/scripts/launch/apply_ses_log_read_policy.sh"
IAM_TF="$REPO_ROOT/ops/iam/fjcloud-instance-role.tf"
TARGET_ACCOUNT="213880904778"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

CLEANUP_DIRS=()
cleanup() {
    local d
    for d in "${CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
    rm -rf "$REPO_ROOT/.test_artifacts"
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Fake command factory. All fakes read FAKE_* env at call time, so a case only
# needs to export overrides before run_apply.
# --------------------------------------------------------------------------

write_fakes() {
    local bin_dir="$1"

    cat > "$bin_dir/aws" <<'AWS'
#!/usr/bin/env bash
set -uo pipefail
[ -n "${FAKE_AWS_CALLLOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_AWS_CALLLOG"
svc="${1:-}"; op="${2:-}"
case "$svc $op" in
  "sts get-caller-identity")
    # Key-gated: the target account is returned only when the loaded access key
    # matches the designated good key. This makes "cleared ambient, loaded file"
    # observable end to end.
    if [ "${AWS_ACCESS_KEY_ID:-}" = "${FAKE_GOOD_KEY:-GOODKEY}" ]; then
      printf '{"Account":"%s","Arn":"arn:aws:iam::%s:user/ci-deployer","UserId":"AIDAEXAMPLE"}' \
        "${FAKE_ACCOUNT_GOOD:-213880904778}" "${FAKE_ACCOUNT_GOOD:-213880904778}"
    else
      printf '{"Account":"999999999999","Arn":"arn:aws:iam::999999999999:user/wrong","UserId":"AIDAWRONG"}'
    fi
    exit 0 ;;
  "ec2 describe-instances") cat "${FAKE_EC2_JSON:?FAKE_EC2_JSON unset}"; exit 0 ;;
  "iam get-instance-profile") cat "${FAKE_PROFILE_JSON:?FAKE_PROFILE_JSON unset}"; exit 0 ;;
  "iam get-role") cat "${FAKE_ROLE_JSON:?FAKE_ROLE_JSON unset}"; exit 0 ;;
  "iam get-role-policy")
    if [ "${FAKE_ROLE_POLICY_MODE:-present}" = "nosuchentity" ]; then
      echo "An error occurred (NoSuchEntity) when calling the GetRolePolicy operation: The role policy with name fjcloud-ses-send-events-read cannot be found." >&2
      exit 254
    fi
    cat "${FAKE_ROLE_POLICY_JSON:?FAKE_ROLE_POLICY_JSON unset}"; exit 0 ;;
esac
echo "unexpected aws call: $*" >&2
exit 99
AWS
    chmod +x "$bin_dir/aws"

    cat > "$bin_dir/terraform" <<'TF'
#!/usr/bin/env bash
set -uo pipefail
# Identify the subcommand (and state sub-op) so the call log records clean
# tokens; logging raw args would let the artifact path (…/apply_ses/…) false-
# match a bare "apply" substring assertion.
sub=""
for a in "$@"; do case "$a" in -chdir=*|-*) continue ;; *) sub="$a"; break ;; esac; done
subop=""
if [ "$sub" = "state" ]; then
  seen=0
  for a in "$@"; do
    case "$a" in
      -chdir=*|-*) continue ;;
      state) seen=1 ;;
      *) [ "$seen" = 1 ] && { subop="$a"; break; } ;;
    esac
  done
fi
[ -n "${FAKE_TF_CALLLOG:-}" ] && printf '%s %s\n' "$sub" "$subop" >> "$FAKE_TF_CALLLOG"
# Full-argv log limited to init: contract tests need to prove which -backend-config
# args the guarded rollout supplies, without polluting subcommand-token assertions.
if [ "$sub" = "init" ] && [ -n "${FAKE_TF_INIT_ARGSLOG:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_TF_INIT_ARGSLOG"
fi
case "$sub" in
  init) echo "Terraform has been successfully initialized!"; exit 0 ;;
  plan) for a in "$@"; do case "$a" in -out=*) : > "${a#-out=}" ;; esac; done; exit "${FAKE_TF_PLAN_RC:-2}" ;;
  show) cat "${FAKE_TF_PLAN_JSON:?FAKE_TF_PLAN_JSON unset}"; exit 0 ;;
  apply) exit "${FAKE_TF_APPLY_RC:-0}" ;;
  import) exit "${FAKE_TF_IMPORT_RC:-0}" ;;
  state)
    case "$subop" in
      pull) cat "${FAKE_TF_STATE_JSON:?FAKE_TF_STATE_JSON unset}"; exit 0 ;;
      list) [ "${FAKE_TF_STATE_LIST_RC:-0}" -ne 0 ] && exit "${FAKE_TF_STATE_LIST_RC}"; printf '%s\n' ${FAKE_TF_STATE_ADDRS:-}; exit 0 ;;
      push|rm) exit 0 ;;
    esac ;;
esac
echo "unexpected terraform call: $*" >&2
exit 98
TF
    chmod +x "$bin_dir/terraform"

cat > "$bin_dir/ssm_exec.sh" <<'SSM'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"
[ -n "${FAKE_SSM_CALLLOG:-}" ] && printf '%s\n' "$cmd" >> "$FAKE_SSM_CALLLOG"
src=""
case "$cmd" in
  *get-caller-identity*) printf '%s' "${FAKE_ONHOST_ARN:-arn:aws:sts::213880904778:assumed-role/fjcloud-instance-role/i-0abc123session}"; exit 0 ;;
  *describe-log-groups*)   src="${FAKE_PROBE_DLG:-}" ;;
  *filter-log-events*)     src="${FAKE_PROBE_FLE:-}" ;;
  *describe-log-streams*)  src="${FAKE_PROBE_DLS:-}" ;;
  *get-log-events*)        src="${FAKE_PROBE_GLE:-}" ;;
  *) echo "unexpected ssm command: $cmd" >&2; exit 97 ;;
esac
if [ "$src" = "DENY" ]; then
  echo "An error occurred (AccessDeniedException) when calling the operation: not authorized" >&2
  exit 1
fi
printf '%s' "$src"
exit 0
SSM
    chmod +x "$bin_dir/ssm_exec.sh"
}

# --------------------------------------------------------------------------
# Per-case fixtures. Writes JSON fixtures into a fresh workspace and exports the
# happy-path defaults; a case overrides individual FAKE_* before run_apply.
# --------------------------------------------------------------------------

new_case() {
    local ws bin fix cred
    ws="$(mktemp -d)"
    CLEANUP_DIRS+=("$ws")
    bin="$ws/bin"; fix="$ws/fix"
    mkdir -p "$bin" "$fix"
    write_fakes "$bin"

    # Credential env-file: source-file AWS keys the script must load AFTER
    # clearing ambient. GOODKEY gates the fake STS to the target account.
    cred="$fix/creds.env"
    printf 'AWS_ACCESS_KEY_ID=GOODKEY\nAWS_SECRET_ACCESS_KEY=goodsecret\n' > "$cred"

    printf '{"Reservations":[{"Instances":[{"InstanceId":"i-0aaa111","State":{"Name":"running"},"IamInstanceProfile":{"Arn":"arn:aws:iam::%s:instance-profile/fjcloud-instance-profile"}}]}]}' \
        "$TARGET_ACCOUNT" > "$fix/ec2.json"
    printf '{"InstanceProfile":{"InstanceProfileName":"fjcloud-instance-profile","Roles":[{"RoleName":"fjcloud-instance-role","RoleId":"AROAEXAMPLE","Arn":"arn:aws:iam::%s:role/fjcloud-instance-role"}]}}' \
        "$TARGET_ACCOUNT" > "$fix/profile.json"

    # Live inline policy fixture derived from the checked-in Terraform owner, so
    # Terraform remains the sole policy-shape source.
    "$SUT" --emit-expected-policy --account="$TARGET_ACCOUNT" --iam-tf="$IAM_TF" 2>/dev/null \
        > "$fix/expected_policy.json" || true
    if [ -s "$fix/expected_policy.json" ]; then
        python3 - "$fix/expected_policy.json" "$fix/rolepolicy.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
json.dump({"RoleName": "fjcloud-instance-role",
          "PolicyName": "fjcloud-ses-send-events-read",
          "PolicyDocument": doc}, open(sys.argv[2], "w"))
PY
    else
        # Script missing (group-1 red): a placeholder so fakes still have a file.
        printf '{"RoleName":"fjcloud-instance-role","PolicyName":"fjcloud-ses-send-events-read","PolicyDocument":{}}' > "$fix/rolepolicy.json"
    fi

    # Safe plan: exactly one intended inline-policy change.
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["update"]}}]}' \
        > "$fix/plan_safe.json"
    printf '{"lineage":"11111111-1111-1111-1111-111111111111","serial":7,"resources":[{"type":"aws_iam_role","name":"fjcloud_instance"}]}' \
        > "$fix/state.json"
    # get-role fixture: correct identity + ec2 trust for the import-identity proof.
    printf '{"Role":{"RoleName":"fjcloud-instance-role","RoleId":"AROAEXAMPLE","Path":"/","Arn":"arn:aws:iam::%s:role/fjcloud-instance-role","AssumeRolePolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Principal":{"Service":"ec2.amazonaws.com"}}]}}}' \
        "$TARGET_ACCOUNT" > "$fix/role.json"
    export FAKE_ROLE_JSON="$fix/role.json"

    CASE_WS="$ws"
    CASE_BIN="$bin"
    CASE_CRED="$cred"
    export FAKE_AWS_CALLLOG="$ws/aws_calls.log"; : > "$FAKE_AWS_CALLLOG"
    export FAKE_SSM_CALLLOG="$ws/ssm_calls.log"; : > "$FAKE_SSM_CALLLOG"
    export FAKE_TF_CALLLOG="$ws/tf_calls.log"; : > "$FAKE_TF_CALLLOG"
    export FAKE_TF_INIT_ARGSLOG="$ws/tf_init_args.log"; : > "$FAKE_TF_INIT_ARGSLOG"
    export FAKE_EC2_JSON="$fix/ec2.json"
    export FAKE_PROFILE_JSON="$fix/profile.json"
    export FAKE_ROLE_POLICY_JSON="$fix/rolepolicy.json"
    export FAKE_TF_PLAN_JSON="$fix/plan_safe.json"
    export FAKE_TF_STATE_JSON="$fix/state.json"
    export FAKE_TF_STATE_ADDRS="aws_iam_role.fjcloud_instance"
    # Good-path on-host probe payloads (simple single-line JSON; cases override).
    export FAKE_PROBE_DLG='{"logGroups":[{"logGroupName":"/fjcloud/staging/ses/send-events"}]}'
    export FAKE_PROBE_FLE='{"events":[]}'
    export FAKE_PROBE_DLS='{"logStreams":[{"logStreamName":"sa"},{"logStreamName":"sb"}]}'
    export FAKE_PROBE_GLE='{"events":[]}'
    unset FAKE_ROLE_POLICY_MODE FAKE_TF_PLAN_RC FAKE_TF_APPLY_RC FAKE_TF_IMPORT_RC \
          FAKE_TF_STATE_LIST_RC FAKE_ONHOST_ARN FAKE_GOOD_KEY FAKE_ACCOUNT_GOOD 2>/dev/null || true
}

RUN_RC=0
RUN_ARTIFACT_ABS=""
run_apply() {
    # Extra args after the two mandatory flags (e.g. --verify-only) are passed through.
    local rel=".test_artifacts/apply_ses/$$_${RANDOM}"
    RUN_ARTIFACT_ABS="$REPO_ROOT/$rel"
    RUN_RC=0
    if [ ! -f "$SUT" ]; then
        RUN_RC=127
        return
    fi
    (
        export PATH="$CASE_BIN:$PATH"
        export APPLY_SES_SSM_EXEC="$CASE_BIN/ssm_exec.sh"
        export APPLY_SES_PROBE_MAX_ATTEMPTS="${APPLY_SES_PROBE_MAX_ATTEMPTS:-3}"
        export APPLY_SES_PROBE_SLEEP_SECONDS="0"
        bash "$SUT" --credential-env-file="$CASE_CRED" --artifact-dir="$rel" "$@"
    ) >"$CASE_WS/stdout.txt" 2>"$CASE_WS/stderr.txt" || RUN_RC=$?
}

# Status from summary.json — or "script_missing" when the SUT does not yet exist,
# so the whole suite reds uniformly for that one reason before implementation.
status() {
    if [ ! -f "$SUT" ]; then echo "script_missing"; return; fi
    sfield "status"
}
sfield() {
    local field="$1" f="$RUN_ARTIFACT_ABS/summary.json"
    [ -f "$f" ] || { echo "NO_SUMMARY"; return; }
    python3 - "$f" "$field" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1]))
cur = obj
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print("MISSING"); sys.exit(0)
print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur, sort_keys=True))
PY
}
stdouterr() { cat "$CASE_WS/stdout.txt" "$CASE_WS/stderr.txt" 2>/dev/null; }

assert_json_equal() {
    local actual="$1" expected="$2" msg="$3"
    if python3 - "$actual" "$expected" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
expected = json.loads(sys.argv[2])
if actual != expected:
    print(json.dumps({"actual": actual, "expected": expected}, indent=2, sort_keys=True))
    raise SystemExit(1)
PY
    then
        pass "$msg"
    else
        fail "$msg"
    fi
}

# ==========================================================================
# Cases
# ==========================================================================

test_script_exists() {
    new_case
    assert_file_exists "$SUT" "guarded rollout script exists and anchors the red"
}

test_relative_credential_file_rejected() {
    new_case
    RUN_RC=0
    if [ ! -f "$SUT" ]; then
        assert_eq "script_missing" "invalid_credential_env_file_not_absolute" "relative credential-env-file is rejected"
        return
    fi
    local rel_out
    rel_out="$(
        export PATH="$CASE_BIN:$PATH" APPLY_SES_SSM_EXEC="$CASE_BIN/ssm_exec.sh"
        bash "$SUT" --credential-env-file="relative/creds.env" --artifact-dir=".test_artifacts/apply_ses/x" 2>&1 || true
    )"
    assert_contains "$rel_out" "credential-env-file must be an absolute path" "relative credential-env-file is rejected with a clear message"
}

test_absolute_artifact_dir_rejected() {
    new_case
    if [ ! -f "$SUT" ]; then
        assert_eq "script_missing" "invalid_artifact_dir_not_relative" "absolute artifact-dir is rejected"
        return
    fi
    local out
    out="$(
        export PATH="$CASE_BIN:$PATH" APPLY_SES_SSM_EXEC="$CASE_BIN/ssm_exec.sh"
        bash "$SUT" --credential-env-file="$CASE_CRED" --artifact-dir="/tmp/abs" 2>&1 || true
    )"
    assert_contains "$out" "artifact-dir must be repo-relative" "absolute artifact-dir is rejected with a clear message"
}

test_emit_expected_policy_matches_known_answer() {
    new_case
    if [ ! -f "$SUT" ]; then
        assert_eq "script_missing" "known_answer_emit_policy" "emit helper is pinned to a hand-written least-privilege policy"
        return
    fi
    local emitted expected
    emitted="$(bash "$SUT" --emit-expected-policy --account="$TARGET_ACCOUNT" --iam-tf="$IAM_TF")"
    expected="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:DescribeLogGroups"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:FilterLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:213880904778:log-group:/fjcloud/staging/ses/send-events:*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:GetLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:213880904778:log-group:/fjcloud/staging/ses/send-events:log-stream:*"
    }
  ]
}
JSON
)"
    assert_json_equal "$emitted" "$expected" "emit helper output matches the independent known-answer policy"
}

test_happy_apply_binds_identity_and_target() {
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply
    assert_eq "$(status)" "success" "clean apply reaches success"
    assert_eq "$(sfield account_id)" "$TARGET_ACCOUNT" "records the target account id"
    assert_eq "$(sfield bound_role_name)" "fjcloud-instance-role" "binds the fjcloud instance role"
    assert_eq "$(sfield bound_instance_id)" "i-0aaa111" "binds the single running staging instance"
    assert_eq "$(sfield profile_name)" "fjcloud-instance-profile" "binds the instance profile"
    assert_eq "$(sfield apply_method)" "terraform_apply" "rc=2 safe plan applies via terraform"
    assert_eq "$(sfield plan_denominator)" "1" "records the plan change denominator"
    assert_eq "$(sfield plan_actions)" '["update"]' "records the intended plan actions"
}

test_cleared_ambient_then_loaded_file_key() {
    # Poison ambient AWS_* must be cleared so the source-file GOODKEY wins;
    # otherwise the fake STS gates to the wrong account.
    new_case
    export FAKE_TF_PLAN_RC=2
    RUN_RC=0
    if [ ! -f "$SUT" ]; then
        assert_eq "script_missing" "success" "ambient AWS_* cleared before loading the credential file"
        return
    fi
    local rel=".test_artifacts/apply_ses/clear_$$_${RANDOM}"
    (
        export PATH="$CASE_BIN:$PATH" APPLY_SES_SSM_EXEC="$CASE_BIN/ssm_exec.sh"
        export APPLY_SES_PROBE_MAX_ATTEMPTS=3 APPLY_SES_PROBE_SLEEP_SECONDS=0
        export AWS_ACCESS_KEY_ID=POISONKEY AWS_SECRET_ACCESS_KEY=poison \
               AWS_SESSION_TOKEN=poisontok AWS_PROFILE=poisonprofile \
               AWS_SHARED_CREDENTIALS_FILE=/tmp/poison
        bash "$SUT" --credential-env-file="$CASE_CRED" --artifact-dir="$rel"
    ) >/dev/null 2>&1 || true
    RUN_ARTIFACT_ABS="$REPO_ROOT/$rel"
    assert_eq "$(sfield status)" "success" "poison ambient AWS_* cleared; source-file key authenticates the target account"
    assert_eq "$(sfield account_id)" "$TARGET_ACCOUNT" "recovered account is the target, not the poison-gated wrong account"
}

test_wrong_account_refused() {
    new_case
    printf 'AWS_ACCESS_KEY_ID=BADKEY\nAWS_SECRET_ACCESS_KEY=s\n' > "$CASE_CRED"
    run_apply
    assert_eq "$(status)" "wrong_account" "non-target account is refused"
    # No writes attempted against the wrong account.
    assert_not_contains "$(cat "$FAKE_TF_CALLLOG")" "apply" "wrong account performs no terraform apply"
}

test_zero_instances_refused() {
    new_case
    printf '{"Reservations":[]}' > "$FAKE_EC2_JSON"
    run_apply
    assert_eq "$(status)" "instance_count_not_one" "zero running instances is refused"
}

test_two_instances_refused() {
    new_case
    printf '{"Reservations":[{"Instances":[{"InstanceId":"i-1","State":{"Name":"running"},"IamInstanceProfile":{"Arn":"arn:aws:iam::%s:instance-profile/fjcloud-instance-profile"}},{"InstanceId":"i-2","State":{"Name":"running"},"IamInstanceProfile":{"Arn":"arn:aws:iam::%s:instance-profile/fjcloud-instance-profile"}}]}]}' \
        "$TARGET_ACCOUNT" "$TARGET_ACCOUNT" > "$FAKE_EC2_JSON"
    run_apply
    assert_eq "$(status)" "instance_count_not_one" "two running instances is refused"
}

test_extra_role_in_profile_refused() {
    new_case
    printf '{"InstanceProfile":{"InstanceProfileName":"fjcloud-instance-profile","Roles":[{"RoleName":"fjcloud-instance-role","RoleId":"AROA1","Arn":"a"},{"RoleName":"other-role","RoleId":"AROA2","Arn":"b"}]}}' \
        > "$FAKE_PROFILE_JSON"
    run_apply
    assert_eq "$(status)" "profile_role_not_unique" "a profile with more than the instance role is refused"
}

test_onhost_role_mismatch_refused() {
    new_case
    export FAKE_ONHOST_ARN="arn:aws:sts::213880904778:assumed-role/some-other-role/i-0abc"
    run_apply
    assert_eq "$(status)" "onhost_role_mismatch" "on-host STS not under fjcloud-instance-role is refused"
}

test_rc0_no_change_is_already_current() {
    new_case
    export FAKE_TF_PLAN_RC=0
    run_apply
    assert_eq "$(status)" "success" "rc=0 with exact live policy reaches success"
    assert_eq "$(sfield apply_method)" "already_current" "rc=0 records already_current, no apply"
    assert_not_contains "$(cat "$FAKE_TF_CALLLOG")" "apply" "rc=0 performs no terraform apply"
}

test_unsafe_plan_multiple_changes_refused() {
    new_case
    export FAKE_TF_PLAN_RC=2
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["update"]}},{"address":"aws_iam_role.fjcloud_instance","change":{"actions":["update"]}}]}' \
        > "$FAKE_TF_PLAN_JSON"
    run_apply
    assert_eq "$(status)" "unsafe_plan_refused" "a plan touching more than the inline policy is refused"
    assert_not_contains "$(cat "$FAKE_TF_CALLLOG")" "apply" "unsafe plan performs no terraform apply"
}

test_unsafe_plan_destroy_action_refused() {
    new_case
    export FAKE_TF_PLAN_RC=2
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["delete"]}}]}' \
        > "$FAKE_TF_PLAN_JSON"
    run_apply
    assert_eq "$(status)" "unsafe_plan_refused" "a delete action on the inline policy is refused"
}

test_no_direct_put_role_policy_fallback() {
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply
    assert_eq "$(status)" "success" "happy path succeeds"
    assert_not_contains "$(cat "$FAKE_AWS_CALLLOG")" "put-role-policy" "no direct aws iam put-role-policy fallback is ever called"
    assert_not_contains "$(cat "$FAKE_AWS_CALLLOG")" "delete-role-policy" "no direct aws iam delete-role-policy fallback is ever called"
}

test_missing_prior_policy_via_nosuchentity() {
    new_case
    export FAKE_ROLE_POLICY_MODE=nosuchentity
    export FAKE_TF_PLAN_RC=2
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["create"]}}]}' \
        > "$FAKE_TF_PLAN_JSON"
    run_apply
    assert_eq "$(status)" "success" "NoSuchEntity prior policy is treated as prior-absent and created"
    assert_eq "$(sfield prior_policy_state)" "absent" "records prior policy state absent for NoSuchEntity"
}

test_broad_live_policy_rolled_back() {
    new_case
    export FAKE_TF_PLAN_RC=0
    printf '{"RoleName":"fjcloud-instance-role","PolicyName":"fjcloud-ses-send-events-read","PolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:*"],"Resource":"*"}]}}' \
        > "$FAKE_ROLE_POLICY_JSON"
    run_apply
    assert_eq "$(status)" "policy_mismatch_refused" "a broad live policy that is not the exact least-privilege shape is refused"
}

test_persistent_denial_preserves_policy() {
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_PROBE_DLG="DENY"
    run_apply
    assert_eq "$(status)" "persistent_authorization_denial" "a persistent AccessDenied on probes is reported without weakening the policy"
    assert_eq "$(sfield api_probes.describe_log_groups)" "denied" "the denied probe is recorded"
    assert_not_contains "$(cat "$FAKE_AWS_CALLLOG")" "put-role-policy" "persistent denial does not broaden the policy"
}

test_probes_record_stream_denominator() {
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply
    assert_eq "$(status)" "success" "all four probes pass on the happy path"
    assert_eq "$(sfield api_probes.describe_log_groups)" "ok" "describe-log-groups probe ok"
    assert_eq "$(sfield api_probes.filter_log_events)" "ok" "filter-log-events probe ok"
    assert_eq "$(sfield api_probes.describe_log_streams)" "ok" "describe-log-streams probe ok"
    assert_eq "$(sfield api_probes.get_log_events)" "ok" "get-log-events probe ok"
    assert_eq "$(sfield stream_denominator)" "2" "records the number of log streams observed"
}

test_probe_shell_quotes_stream_name() {
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_PROBE_DLS='{"logStreams":[{"logStreamName":"stream name;touch /tmp/pwn"}]}'
    run_apply
    assert_eq "$(status)" "success" "shell-sensitive log stream names do not break probe execution"
    local ssm; ssm="$(cat "$FAKE_SSM_CALLLOG")"
    assert_contains "$ssm" 'stream\ name\;touch\ /tmp/pwn' \
        "get-log-events probe shell-quotes the remote log stream name"
    assert_not_contains "$ssm" "--log-stream-name stream name;touch /tmp/pwn" \
        "get-log-events probe never emits the raw unquoted stream name"
}

test_probe_retries_only_access_denied_then_succeeds() {
    # First attempt denied, later attempts ok — the transient AccessDenied is
    # retried (propagation lag) rather than treated as a hard failure.
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_PROBE_FLE="RETRY"   # sentinel handled by a stateful fake below
    # Re-point filter-log-events at a stateful fake using a counter file.
    local counter="$CASE_WS/fle_counter"
    echo 0 > "$counter"
    cat > "$CASE_BIN/ssm_exec.sh" <<SSM
#!/usr/bin/env bash
set -uo pipefail
cmd="\${1:-}"
case "\$cmd" in
  *get-caller-identity*) printf '%s' "arn:aws:sts::213880904778:assumed-role/fjcloud-instance-role/i-0abc"; exit 0 ;;
  *describe-log-groups*) printf '%s' '{"logGroups":[{"logGroupName":"/fjcloud/staging/ses/send-events"}]}'; exit 0 ;;
  *filter-log-events*)
    n="\$(cat "$counter")"; echo \$((n+1)) > "$counter"
    if [ "\$n" -lt 1 ]; then
      echo "An error occurred (AccessDeniedException) not authorized" >&2; exit 1
    fi
    printf '%s' '{"events":[]}'; exit 0 ;;
  *describe-log-streams*) printf '%s' '{"logStreams":[{"logStreamName":"sa"}]}'; exit 0 ;;
  *get-log-events*) printf '%s' '{"events":[]}'; exit 0 ;;
esac
echo "unexpected ssm command: \$cmd" >&2; exit 97
SSM
    chmod +x "$CASE_BIN/ssm_exec.sh"
    run_apply
    assert_eq "$(status)" "success" "a transient AccessDenied on a probe is retried to success"
    local attempts; attempts="$(sfield propagation_attempts)"
    if [ "$attempts" != "MISSING" ] && [ "$attempts" != "NO_SUMMARY" ]; then
        assert_ne "$attempts" "1" "more than one propagation attempt is recorded after a retry"
    else
        fail "propagation_attempts recorded (got '$attempts')"
    fi
}

test_missing_role_state_imports_by_name() {
    # Role bound in AWS but absent from Terraform state → narrow import by name.
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_TF_STATE_ADDRS=""   # role not yet in state
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["create"]}}]}' \
        > "$FAKE_TF_PLAN_JSON"
    run_apply
    assert_eq "$(status)" "success" "missing role state is reconciled by import and the apply proceeds"
    assert_eq "$(sfield state_reconciliation)" "performed" "records that state reconciliation was performed"
    assert_eq "$(sfield apply_method)" "state_reconciled_apply" "apply method reflects the reconciliation path"
    assert_contains "$(cat "$FAKE_TF_CALLLOG")" "import" "reconciliation runs terraform import"
}

test_import_then_unsafe_plan_rolls_back() {
    # Role imported into state, but the post-import plan is NOT the single
    # intended change → the freshly-imported address is rolled back out of state
    # and the run fails closed, exactly as the runbook promises.
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_TF_STATE_ADDRS=""   # role absent → the import path is taken
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["update"]}},{"address":"aws_iam_role.fjcloud_instance","change":{"actions":["update"]}}]}' \
        > "$FAKE_TF_PLAN_JSON"
    run_apply
    assert_eq "$(status)" "unsafe_plan_refused" "an unsafe post-import plan is refused"
    assert_eq "$(sfield state_reconciliation)" "rolled_back" "the imported address is rolled back out of state on an unsafe plan"
    local tf; tf="$(cat "$FAKE_TF_CALLLOG")"
    assert_contains "$tf" "import" "the reconciliation import ran before the unsafe plan"
    assert_contains "$tf" "state rm" "the imported address is removed from state on refusal"
    assert_not_contains "$tf" "apply" "an unsafe post-import plan performs no terraform apply"
}

test_unreadable_state_list_refuses_without_import() {
    # `terraform state list` failing must fail closed — an unreadable state is
    # NOT evidence the role is absent, so no import or state rm may run.
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_TF_STATE_LIST_RC=1   # state list cannot read the state
    run_apply
    assert_eq "$(status)" "state_reconciliation_failed" "an unreadable state list fails closed"
    local tf; tf="$(cat "$FAKE_TF_CALLLOG")"
    assert_not_contains "$tf" "import" "an unreadable state list runs no terraform import"
    assert_not_contains "$tf" "state rm" "an unreadable state list runs no terraform state rm"
    assert_not_contains "$tf" "apply" "an unreadable state list performs no terraform apply"
}

test_import_then_apply_failure_rolls_back() {
    # Role imported into state and the plan is the single intended change, but
    # `terraform apply` of the saved plan fails → the freshly-imported address
    # must be rolled back out of state so a failed rollout leaves no half-
    # reconciled state behind.
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_TF_STATE_ADDRS=""   # role absent → the import path is taken
    export FAKE_TF_APPLY_RC=1       # apply of the saved plan fails
    printf '{"resource_changes":[{"address":"aws_iam_role_policy.fjcloud_ses_send_events_read","change":{"actions":["create"]}}]}' \
        > "$FAKE_TF_PLAN_JSON"
    run_apply
    assert_eq "$(status)" "terraform_apply_failed" "a failed apply after import fails closed"
    assert_eq "$(sfield state_reconciliation)" "rolled_back" "the imported address is rolled back out of state on apply failure"
    local tf; tf="$(cat "$FAKE_TF_CALLLOG")"
    assert_contains "$tf" "import" "the reconciliation import ran before the failed apply"
    assert_contains "$tf" "state rm" "the imported address is removed from state on apply failure"
}

test_wrong_trust_role_refuses_import() {
    new_case
    export FAKE_TF_PLAN_RC=2
    export FAKE_TF_STATE_ADDRS=""
    # Wrong trust principal → import identity proof must refuse.
    printf '{"Role":{"RoleName":"fjcloud-instance-role","RoleId":"AROAX","Path":"/","Arn":"a","AssumeRolePolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Principal":{"Service":"lambda.amazonaws.com"}}]}}}' \
        > "$FAKE_ROLE_JSON"
    run_apply
    assert_eq "$(status)" "state_reconciliation_failed" "a role whose trust is not EC2 is refused before import"
    assert_not_contains "$(cat "$FAKE_TF_CALLLOG")" "import" "refused reconciliation runs no terraform import"
}

test_verify_only_performs_zero_writes() {
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply --verify-only
    assert_eq "$(status)" "verify_only_complete" "verify-only completes without mutation"
    assert_eq "$(sfield verify_only)" "True" "summary records verify_only true"
    local tf; tf="$(cat "$FAKE_TF_CALLLOG")"
    assert_not_contains "$tf" "apply" "verify-only performs no terraform apply"
    assert_not_contains "$tf" "import" "verify-only performs no terraform import"
    assert_not_contains "$(cat "$FAKE_AWS_CALLLOG")" "put-role-policy" "verify-only writes no policy directly"
}

test_secure_artifacts_and_no_secret_leak() {
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply
    assert_eq "$(status)" "success" "happy path for artifact assertions"
    # Prior policy snapshot exists and is 0600.
    local snap="$RUN_ARTIFACT_ABS/prior_policy.json"
    if [ -f "$snap" ]; then
        local mode; mode="$(stat -f '%Lp' "$snap" 2>/dev/null || stat -c '%a' "$snap")"
        assert_eq "$mode" "600" "prior policy snapshot is chmod 0600"
    else
        fail "prior policy snapshot written to artifact dir"
    fi
    # The apply JSON is deleted immediately after use.
    assert_path_absent "$RUN_ARTIFACT_ABS/new_policy_apply.json" "NEW_POLICY_APPLY_JSON is deleted after write"
    # No source-file secret value leaks to stdout/stderr or summary.
    local blob; blob="$(stdouterr; cat "$RUN_ARTIFACT_ABS/summary.json" 2>/dev/null)"
    assert_not_contains "$blob" "goodsecret" "no secret access key value leaks to output or summary"
    assert_not_contains "$blob" "GOODKEY" "no access key id value leaks to output or summary"
    # Caller/profile facts are sanitized.
    assert_contains "$(sfield caller_arn_sanitized)" ":user/REDACTED" "caller arn leaf is redacted"
    assert_not_contains "$(sfield caller_arn_sanitized)" "ci-deployer" "raw caller principal name is not recorded"
}

assert_path_absent() {
    local p="$1" msg="$2"
    if [ -e "$p" ]; then fail "$msg (unexpected: $p)"; else pass "$msg"; fi
}

test_guarded_init_uses_canonical_iam_state_key() {
    # ops/iam/backend.tf owns key="iam/terraform.tfstate"; the guarded rollout
    # must reconfigure the S3 backend against that exact object. A bare
    # "terraform.tfstate" key silently forks state into a parallel object and
    # would let apply "succeed" against a stale/empty backend.
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply
    if [ ! -f "$SUT" ]; then
        assert_eq "script_missing" "success" "guarded init uses key=iam/terraform.tfstate"
        return
    fi
    assert_eq "$(status)" "success" "happy path succeeds so init actually ran"
    local args; args="$(cat "$FAKE_TF_INIT_ARGSLOG")"
    assert_contains "$args" "-backend-config=key=iam/terraform.tfstate" \
        "guarded init passes the canonical IAM backend key"
    assert_not_contains "$args" "-backend-config=key=terraform.tfstate" \
        "guarded init never passes the non-canonical root backend key"
}

test_summary_json_is_valid_and_complete() {
    new_case
    export FAKE_TF_PLAN_RC=2
    run_apply
    if [ ! -f "$SUT" ]; then
        assert_eq "script_missing" "valid" "summary.json is valid and complete"
        return
    fi
    assert_valid_json "$(cat "$RUN_ARTIFACT_ABS/summary.json")" "summary.json is valid JSON"
    local field
    for field in status source_sha apply_method verify_only account_id caller_arn_sanitized \
                 profile_name bound_instance_id bound_role_name onhost_role_arn_sanitized \
                 plan_denominator plan_actions prior_policy_state state_reconciliation \
                 api_probes stream_denominator propagation_attempts cleanup; do
        local v; v="$(sfield "$field")"
        assert_ne "$v" "MISSING" "summary.json has field $field"
    done
    # source SHA is a real commit hash.
    local sha; sha="$(sfield source_sha)"
    if [ "${#sha}" -ge 7 ]; then pass "source_sha looks like a commit hash"; else fail "source_sha looks like a commit hash (got '$sha')"; fi
}

# --------------------------------------------------------------------------
test_script_exists
test_relative_credential_file_rejected
test_absolute_artifact_dir_rejected
test_emit_expected_policy_matches_known_answer
test_happy_apply_binds_identity_and_target
test_cleared_ambient_then_loaded_file_key
test_wrong_account_refused
test_zero_instances_refused
test_two_instances_refused
test_extra_role_in_profile_refused
test_onhost_role_mismatch_refused
test_rc0_no_change_is_already_current
test_unsafe_plan_multiple_changes_refused
test_unsafe_plan_destroy_action_refused
test_no_direct_put_role_policy_fallback
test_missing_prior_policy_via_nosuchentity
test_broad_live_policy_rolled_back
test_persistent_denial_preserves_policy
test_probes_record_stream_denominator
test_probe_shell_quotes_stream_name
test_probe_retries_only_access_denied_then_succeeds
test_missing_role_state_imports_by_name
test_import_then_unsafe_plan_rolls_back
test_unreadable_state_list_refuses_without_import
test_import_then_apply_failure_rolls_back
test_wrong_trust_role_refuses_import
test_verify_only_performs_zero_writes
test_secure_artifacts_and_no_secret_leak
test_guarded_init_uses_canonical_iam_state_key
test_summary_json_is_valid_and_complete

echo "----"
echo "apply_ses_log_read_policy_test: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
