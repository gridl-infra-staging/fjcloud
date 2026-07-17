#!/usr/bin/env bash
# apply_ses_log_read_policy.sh — guarded rollout of the least-privilege SES
# send-events CloudWatch Logs read policy onto the staging fjcloud instance role.
#
# WHY A GUARDED CLI (not a bare `terraform apply`)
# ------------------------------------------------
# The policy shape is owned, and only owned, by Terraform at
# ops/iam/fjcloud-instance-role.tf (resource fjcloud_ses_send_events_read). This
# script derives the intended shape FROM that owner, binds the exact staging
# target three independent ways (single running instance, single-role profile,
# on-host STS proof), and only lets Terraform apply when the saved plan changes
# nothing but that one inline policy. It never hand-writes a policy JSON and
# never falls back to `aws iam put-role-policy`, so there is no second policy
# author and no path that can silently broaden the grant.
#
# Usage:
#   scripts/launch/apply_ses_log_read_policy.sh \
#       --credential-env-file=/absolute/path/to/.env.secret \
#       --artifact-dir=<repo-relative-dir> [--verify-only]
#
#   --verify-only  Run every read-only proof and the four on-host API probes
#                  WITHOUT any Terraform mutation. Used to confirm a prior apply
#                  landed, or as the transition check before the six-row rerun.
#
# Internal helper mode (used by tests / fixtures to keep one normalizer):
#   scripts/launch/apply_ses_log_read_policy.sh --emit-expected-policy \
#       --account=<id> --iam-tf=<path>
#
# Exit: 0 on success|verify_only_complete, 1 on any refusal (summary.json still
# written), 2 on CLI misuse (before any artifact dir exists).
#
# NOTE: intentionally NOT `set -e`. The guarded flow captures `terraform plan
# -detailed-exitcode` return codes (0 = no change, 2 = change) explicitly; a
# global errexit would lose that signal. Return codes are checked by hand.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck disable=SC1091
# shellcheck source=scripts/lib/aws_identity.sh
source "$REPO_ROOT/scripts/lib/aws_identity.sh"

readonly TARGET_ACCOUNT="213880904778"
readonly TARGET_ROLE="fjcloud-instance-role"
readonly INLINE_POLICY_NAME="fjcloud-ses-send-events-read"
readonly ROLE_TF_ADDR="aws_iam_role.fjcloud_instance"
readonly INSTANCE_TAG="fjcloud-api-staging"
readonly LOG_GROUP="/fjcloud/staging/ses/send-events"
readonly REGION="us-east-1"
readonly TFSTATE_BUCKET="fjcloud-tfstate-staging"
readonly IAM_TF="$REPO_ROOT/ops/iam/fjcloud-instance-role.tf"
readonly IAM_CHDIR="$REPO_ROOT/ops/iam"

SSM_EXEC="${APPLY_SES_SSM_EXEC:-$SCRIPT_DIR/ssm_exec_staging.sh}"
PROBE_MAX_ATTEMPTS="${APPLY_SES_PROBE_MAX_ATTEMPTS:-20}"
PROBE_SLEEP_SECONDS="${APPLY_SES_PROBE_SLEEP_SECONDS:-15}"

# --------------------------------------------------------------------------
# Embedded Python helper (JSON/HCL parsing that bash cannot do safely). Written
# to a temp file once so data can still arrive on stdin.
# --------------------------------------------------------------------------
PYHELPER="$(mktemp)"
trap 'rm -f "$PYHELPER"' EXIT

cat > "$PYHELPER" <<'PYEOF'
import json, os, re, sys, urllib.parse

def _stdin():
    raw = sys.stdin.read()
    return json.loads(raw)

def _canon(doc):
    if isinstance(doc, dict) and "PolicyDocument" in doc:
        doc = doc["PolicyDocument"]
    if isinstance(doc, str):
        doc = json.loads(urllib.parse.unquote(doc))
    stmts = doc.get("Statement", [])
    if isinstance(stmts, dict):
        stmts = [stmts]
    norm = []
    for s in stmts:
        act = s.get("Action")
        if isinstance(act, str):
            act = [act]
        res = s.get("Resource")
        if isinstance(res, list):
            res = sorted(res)
        entry = {"Effect": s.get("Effect"), "Action": sorted(act or []), "Resource": res}
        if "Condition" in s:
            entry["Condition"] = s["Condition"]
        norm.append(json.dumps(entry, sort_keys=True))
    norm.sort()
    return json.dumps({"Version": doc.get("Version"), "Statement": norm}, sort_keys=True)

def _resource_block(text, name):
    m = re.search(r'resource\s+"aws_iam_role_policy"\s+"%s"\s*\{' % re.escape(name), text)
    if not m:
        return None
    depth = 0
    start = m.end() - 1
    for j in range(start, len(text)):
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return None

def _brace_objects(text):
    objs, depth, obj_start = [], 0, None
    for j, c in enumerate(text):
        if c == '{':
            if depth == 0:
                obj_start = j
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                objs.append(text[obj_start:j + 1])
    return objs

def cmd_emit(tf_path, account):
    text = open(tf_path).read()
    block = _resource_block(text, "fjcloud_ses_send_events_read")
    if block is None:
        sys.stderr.write("emit: ses_send_events_read policy block not found\n")
        sys.exit(3)
    version_m = re.search(r'Version\s*=\s*"([^"]+)"', block)
    version = version_m.group(1) if version_m else "2012-10-17"
    sm = re.search(r'Statement\s*=\s*\[', block)
    start = sm.end() - 1
    depth = 0
    stmt_text = ""
    for j in range(start, len(block)):
        if block[j] == '[':
            depth += 1
        elif block[j] == ']':
            depth -= 1
            if depth == 0:
                stmt_text = block[start:j + 1]
                break
    statements = []
    for o in _brace_objects(stmt_text):
        eff = re.search(r'Effect\s*=\s*"([^"]+)"', o).group(1)
        actions = re.findall(r'"([^"]+)"', re.search(r'Action\s*=\s*\[([^\]]*)\]', o).group(1))
        rlist = re.search(r'Resource\s*=\s*\[([^\]]*)\]', o)
        if rlist:
            resource = re.findall(r'"([^"]+)"', rlist.group(1))
        else:
            resource = re.search(r'Resource\s*=\s*"([^"]*)"', o).group(1)
        placeholder = "${data.aws_caller_identity.current.account_id}"
        if isinstance(resource, list):
            resource = [x.replace(placeholder, account) for x in resource]
        else:
            resource = resource.replace(placeholder, account)
        statements.append({"Effect": eff, "Action": actions, "Resource": resource})
    print(json.dumps({"Version": version, "Statement": statements}))

def cmd_canon():
    print(_canon(_stdin()))

def cmd_analyze_plan():
    data = _stdin()
    mutating = []
    for c in data.get("resource_changes", []):
        actions = c.get("change", {}).get("actions", [])
        if actions in (["no-op"], ["read"]):
            continue
        mutating.append(c)
    denom = len(mutating)
    actions, safe = [], 0
    if denom == 1:
        c = mutating[0]
        actions = c.get("change", {}).get("actions", [])
        if c.get("address", "").endswith("aws_iam_role_policy.fjcloud_ses_send_events_read") \
                and set(actions) <= {"create", "update"}:
            safe = 1
    print("%d\t%s\t%d" % (denom, json.dumps(actions), safe))

def cmd_parse_ec2():
    data = _stdin()
    insts = []
    for r in data.get("Reservations", []):
        for i in r.get("Instances", []):
            insts.append((i.get("InstanceId") or "", (i.get("IamInstanceProfile") or {}).get("Arn") or ""))
    print(len(insts))
    if insts:
        print(insts[0][0])
        print(insts[0][1])

def cmd_parse_profile():
    data = _stdin()
    roles = data.get("InstanceProfile", {}).get("Roles", [])
    print(len(roles))
    if roles:
        print(roles[0].get("RoleName", ""))
        print(roles[0].get("RoleId", ""))

def cmd_parse_streams():
    data = _stdin()
    streams = data.get("logStreams", [])
    print(len(streams))
    print(streams[0].get("logStreamName", "") if streams else "")

def cmd_has_key(key):
    try:
        data = _stdin()
    except Exception:
        sys.exit(1)
    sys.exit(0 if isinstance(data, dict) and key in data else 1)

def cmd_assert_role(expected_name):
    data = _stdin()
    role = data.get("Role", {})
    trust = role.get("AssumeRolePolicyDocument", {})
    if isinstance(trust, str):
        trust = json.loads(urllib.parse.unquote(trust))
    principals = []
    for st in trust.get("Statement", []):
        svc = st.get("Principal", {}).get("Service")
        if isinstance(svc, list):
            principals += svc
        elif svc:
            principals.append(svc)
    ok = role.get("RoleName") == expected_name and "ec2.amazonaws.com" in principals
    sys.exit(0 if ok else 1)

def _b(name):
    return os.environ.get(name, "false").lower() == "true"

def cmd_write_summary(out_path):
    e = os.environ.get
    summary = {
        "status": e("SUMMARY_STATUS", ""),
        "source_sha": e("SUMMARY_SOURCE_SHA", ""),
        "apply_method": e("SUMMARY_APPLY_METHOD", "none"),
        "verify_only": _b("SUMMARY_VERIFY_ONLY"),
        "account_id": e("SUMMARY_ACCOUNT_ID", ""),
        "caller_arn_sanitized": e("SUMMARY_CALLER_ARN", ""),
        "profile_name": e("SUMMARY_PROFILE_NAME", ""),
        "bound_instance_id": e("SUMMARY_BOUND_INSTANCE_ID", ""),
        "bound_role_name": e("SUMMARY_BOUND_ROLE_NAME", ""),
        "onhost_role_arn_sanitized": e("SUMMARY_ONHOST_ARN", ""),
        "plan_denominator": int(e("SUMMARY_PLAN_DENOMINATOR", "0")),
        "plan_actions": json.loads(e("SUMMARY_PLAN_ACTIONS", "[]")),
        "prior_policy_state": e("SUMMARY_PRIOR_POLICY_STATE", "unknown"),
        "policy_match": e("SUMMARY_POLICY_MATCH", "n/a"),
        "state_reconciliation": e("SUMMARY_STATE_RECONCILIATION", "not_needed"),
        "api_probes": {
            "describe_log_groups": e("SUMMARY_PROBE_DLG", "skipped"),
            "filter_log_events": e("SUMMARY_PROBE_FLE", "skipped"),
            "describe_log_streams": e("SUMMARY_PROBE_DLS", "skipped"),
            "get_log_events": e("SUMMARY_PROBE_GLE", "skipped"),
        },
        "stream_denominator": int(e("SUMMARY_STREAM_DENOMINATOR", "0")),
        "propagation_attempts": int(e("SUMMARY_PROPAGATION_ATTEMPTS", "0")),
        "cleanup": {
            "new_policy_apply_json_deleted": _b("SUMMARY_CLEANUP_NEWJSON"),
            "prior_policy_snapshot": e("SUMMARY_CLEANUP_PRIOR", "not_created"),
            "state_snapshot": e("SUMMARY_CLEANUP_STATE", "not_created"),
        },
    }
    with open(out_path, "w") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)

def main():
    cmd = sys.argv[1]
    rest = sys.argv[2:]
    dispatch = {
        "emit": cmd_emit, "canon": cmd_canon, "analyze-plan": cmd_analyze_plan,
        "parse-ec2": cmd_parse_ec2, "parse-profile": cmd_parse_profile,
        "parse-streams": cmd_parse_streams, "has-key": cmd_has_key,
        "assert-role": cmd_assert_role, "write-summary": cmd_write_summary,
    }
    dispatch[cmd](*rest)

main()
PYEOF

py() { python3 "$PYHELPER" "$@"; }

read_py_lines() {
    local target="$1"
    local input="$2"
    shift 2
    local line
    eval "$target=()"
    while IFS= read -r line; do
        eval "$target+=(\"\$line\")"
    done < <(printf '%s' "$input" | py "$@")
}

# --------------------------------------------------------------------------
# Summary state (single source for summary.json)
# --------------------------------------------------------------------------
SUMMARY_STATUS=""
SUMMARY_SOURCE_SHA=""
SUMMARY_APPLY_METHOD="none"
SUMMARY_VERIFY_ONLY="false"
SUMMARY_ACCOUNT_ID=""
SUMMARY_CALLER_ARN=""
SUMMARY_PROFILE_NAME=""
SUMMARY_BOUND_INSTANCE_ID=""
SUMMARY_BOUND_ROLE_NAME=""
SUMMARY_ONHOST_ARN=""
SUMMARY_PLAN_DENOMINATOR="0"
SUMMARY_PLAN_ACTIONS="[]"
SUMMARY_PRIOR_POLICY_STATE="unknown"
SUMMARY_POLICY_MATCH="n/a"
SUMMARY_STATE_RECONCILIATION="not_needed"
SUMMARY_PROBE_DLG="skipped"
SUMMARY_PROBE_FLE="skipped"
SUMMARY_PROBE_DLS="skipped"
SUMMARY_PROBE_GLE="skipped"
SUMMARY_STREAM_DENOMINATOR="0"
SUMMARY_PROPAGATION_ATTEMPTS="0"
SUMMARY_CLEANUP_NEWJSON="false"
SUMMARY_CLEANUP_PRIOR="not_created"
SUMMARY_CLEANUP_STATE="not_created"

ARTIFACT_DIR=""

write_summary() {
    [ -n "$ARTIFACT_DIR" ] || return 0
    export SUMMARY_STATUS SUMMARY_SOURCE_SHA SUMMARY_APPLY_METHOD SUMMARY_VERIFY_ONLY \
        SUMMARY_ACCOUNT_ID SUMMARY_CALLER_ARN SUMMARY_PROFILE_NAME SUMMARY_BOUND_INSTANCE_ID \
        SUMMARY_BOUND_ROLE_NAME SUMMARY_ONHOST_ARN SUMMARY_PLAN_DENOMINATOR SUMMARY_PLAN_ACTIONS \
        SUMMARY_PRIOR_POLICY_STATE SUMMARY_POLICY_MATCH SUMMARY_STATE_RECONCILIATION \
        SUMMARY_PROBE_DLG SUMMARY_PROBE_FLE SUMMARY_PROBE_DLS SUMMARY_PROBE_GLE \
        SUMMARY_STREAM_DENOMINATOR SUMMARY_PROPAGATION_ATTEMPTS \
        SUMMARY_CLEANUP_NEWJSON SUMMARY_CLEANUP_PRIOR SUMMARY_CLEANUP_STATE
    py write-summary "$ARTIFACT_DIR/summary.json"
}

die_cli() { echo "ERROR: $*" >&2; exit 2; }

die_status() {
    SUMMARY_STATUS="$1"; shift
    [ "$#" -gt 0 ] && echo "REFUSED[$SUMMARY_STATUS]: $*" >&2
    write_summary
    exit 1
}

# Redact the trailing principal/session leaf of an ARN, keeping the role name
# (second-to-last segment) intact for auditability.
sanitize_arn() {
    local arn="$1"
    [ -n "$arn" ] || { printf ''; return; }
    printf '%s/REDACTED' "${arn%/*}"
}

shell_join_for_exec() {
    local parts=() arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        parts+=("$arg")
    done
    local IFS=' '
    printf '%s\n' "${parts[*]}"
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
MODE="apply"
CRED_FILE=""
ARTIFACT_DIR_REL=""
VERIFY_ONLY="false"
EMIT_ACCOUNT=""
EMIT_IAM_TF=""

for arg in "$@"; do
    case "$arg" in
        --emit-expected-policy) MODE="emit" ;;
        --account=*) EMIT_ACCOUNT="${arg#*=}" ;;
        --iam-tf=*) EMIT_IAM_TF="${arg#*=}" ;;
        --credential-env-file=*) CRED_FILE="${arg#*=}" ;;
        --artifact-dir=*) ARTIFACT_DIR_REL="${arg#*=}" ;;
        --verify-only) VERIFY_ONLY="true" ;;
        *) die_cli "unknown argument: $arg" ;;
    esac
done

if [ "$MODE" = "emit" ]; then
    [ -n "$EMIT_ACCOUNT" ] || die_cli "--emit-expected-policy requires --account"
    [ -n "$EMIT_IAM_TF" ] || EMIT_IAM_TF="$IAM_TF"
    py emit "$EMIT_IAM_TF" "$EMIT_ACCOUNT"
    exit 0
fi

# --- CLI validation (before any artifact dir exists) ---
case "$CRED_FILE" in
    /*) : ;;
    *) die_cli "--credential-env-file must be an absolute path (got '$CRED_FILE')" ;;
esac
case "$ARTIFACT_DIR_REL" in
    /*) die_cli "--artifact-dir must be repo-relative, not absolute (got '$ARTIFACT_DIR_REL')" ;;
    *..*) die_cli "--artifact-dir must be repo-relative and may not contain '..' (got '$ARTIFACT_DIR_REL')" ;;
    "") die_cli "--artifact-dir is required" ;;
    *) : ;;
esac

ARTIFACT_DIR="$REPO_ROOT/$ARTIFACT_DIR_REL"
mkdir -p "$ARTIFACT_DIR"
SUMMARY_VERIFY_ONLY="$VERIFY_ONLY"
SUMMARY_SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

# ==========================================================================
# Phase 1 — Credentials + caller identity (clear ambient, load file, verify)
# ==========================================================================
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE
[ -f "$CRED_FILE" ] || die_status credential_env_file_missing "no file at $CRED_FILE"
load_env_file "$CRED_FILE"

aws_identity_ensure "$CRED_FILE" || true
case "$AWS_IDENTITY_STATUS" in
    valid|recovered) : ;;
    *) die_status identity_invalid "$AWS_IDENTITY_DIAGNOSTIC" ;;
esac
SUMMARY_ACCOUNT_ID="$AWS_IDENTITY_ACCOUNT"
SUMMARY_CALLER_ARN="$(sanitize_arn "$AWS_IDENTITY_ARN")"
[ "$AWS_IDENTITY_ACCOUNT" = "$TARGET_ACCOUNT" ] \
    || die_status wrong_account "identity account $AWS_IDENTITY_ACCOUNT is not target $TARGET_ACCOUNT"

# ==========================================================================
# Phase 2 — Bind the exact staging target (three independent proofs)
# ==========================================================================
ec2_json="$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_TAG" "Name=instance-state-name,Values=running" \
    --output json 2>/dev/null)" || die_status aws_ec2_describe_failed "ec2 describe-instances failed"

ec2_fields=()
read_py_lines ec2_fields "$ec2_json" parse-ec2
ec2_count="${ec2_fields[0]:-0}"
[ "$ec2_count" = "1" ] || die_status instance_count_not_one \
    "expected exactly one running $INSTANCE_TAG instance, found $ec2_count"
SUMMARY_BOUND_INSTANCE_ID="${ec2_fields[1]:-}"
profile_arn="${ec2_fields[2]:-}"
[ -n "$profile_arn" ] || die_status instance_count_not_one "instance has no attached instance profile"
profile_name="${profile_arn##*/}"
SUMMARY_PROFILE_NAME="$profile_name"

profile_json="$(aws iam get-instance-profile --instance-profile-name "$profile_name" \
    --output json 2>/dev/null)" || die_status aws_get_profile_failed "get-instance-profile failed"
profile_fields=()
read_py_lines profile_fields "$profile_json" parse-profile
role_count="${profile_fields[0]:-0}"
role_name="${profile_fields[1]:-}"
{ [ "$role_count" = "1" ] && [ "$role_name" = "$TARGET_ROLE" ]; } \
    || die_status profile_role_not_unique \
       "profile must bind exactly the $TARGET_ROLE role (found count=$role_count name=$role_name)"
SUMMARY_BOUND_ROLE_NAME="$role_name"

onhost_arn="$("$SSM_EXEC" "$(shell_join_for_exec aws sts get-caller-identity --query Arn --output text)" 2>/dev/null)" \
    || die_status onhost_sts_failed "on-host STS proof did not return an ARN"
case "$onhost_arn" in
    arn:aws:sts::*:assumed-role/"$TARGET_ROLE"/*) : ;;
    *) die_status onhost_role_mismatch "on-host STS ARN not under $TARGET_ROLE: $(sanitize_arn "$onhost_arn")" ;;
esac
SUMMARY_ONHOST_ARN="$(sanitize_arn "$onhost_arn")"

# ==========================================================================
# Phase 3 — Derive intended shape from Terraform owner; compare live exactly
# ==========================================================================
new_policy_json="$ARTIFACT_DIR/new_policy_apply.json"
py emit "$IAM_TF" "$TARGET_ACCOUNT" > "$new_policy_json"
chmod 0600 "$new_policy_json"
expected_canon="$(py canon < "$new_policy_json")"
# The derived JSON is transient scaffolding, never an authored owner: delete it
# immediately after deriving the canonical form so no second policy file lingers.
rm -f "$new_policy_json"
SUMMARY_CLEANUP_NEWJSON="true"

live_err="$ARTIFACT_DIR/.getrolepolicy.err"
if live_json="$(aws iam get-role-policy --role-name "$TARGET_ROLE" \
        --policy-name "$INLINE_POLICY_NAME" --output json 2>"$live_err")"; then
    SUMMARY_PRIOR_POLICY_STATE="present"
    prior_snapshot="$ARTIFACT_DIR/prior_policy.json"
    printf '%s' "$live_json" > "$prior_snapshot"
    chmod 0600 "$prior_snapshot"
    SUMMARY_CLEANUP_PRIOR="kept"
    live_canon="$(printf '%s' "$live_json" | py canon)"
    if [ "$live_canon" = "$expected_canon" ]; then
        SUMMARY_POLICY_MATCH="exact"
    else
        SUMMARY_POLICY_MATCH="mismatch"
        rm -f "$live_err"
        die_status policy_mismatch_refused \
            "live inline policy is not the exact least-privilege shape; refusing without any mutation"
    fi
else
    if grep -q "NoSuchEntity" "$live_err"; then
        SUMMARY_PRIOR_POLICY_STATE="absent"
        SUMMARY_POLICY_MATCH="n/a"
    else
        rm -f "$live_err"
        die_status aws_get_role_policy_failed "get-role-policy failed for a non-NoSuchEntity reason"
    fi
fi
rm -f "$live_err"

# ==========================================================================
# Phase 4 — Guarded Terraform apply (skipped entirely under --verify-only)
# ==========================================================================
tf() { terraform -chdir="$IAM_CHDIR" "$@"; }

reconcile_role_state_if_needed() {
    # `state list` is a hard gate, not a best-effort probe: an unreadable state
    # must fail closed. Treating a read failure as "role absent" would drive an
    # unnecessary import (and, on import failure, a state rm) against a state
    # layout we never successfully read — exactly the unsafe mutation this
    # guarded CLI exists to prevent. No import/state rm runs on this branch.
    local state_list rc=0
    state_list="$(tf state list 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || die_status state_reconciliation_failed \
        "terraform state list failed; refusing to reconcile from an unreadable state (no import or state rm performed)"
    if printf '%s\n' "$state_list" | grep -qx "$ROLE_TF_ADDR"; then
        return 0
    fi
    # Role exists in AWS (bound above) but not in Terraform state — narrowly
    # import it by name after proving identity + trust, snapshotting state first.
    SUMMARY_STATE_RECONCILIATION="performed"
    local role_json snapshot
    role_json="$(aws iam get-role --role-name "$TARGET_ROLE" --output json 2>/dev/null)" \
        || die_status state_reconciliation_failed "could not read role for import identity proof"
    printf '%s' "$role_json" | py assert-role "$TARGET_ROLE" \
        || die_status state_reconciliation_failed "role identity/trust does not match $TARGET_ROLE; refusing import"
    snapshot="$ARTIFACT_DIR/state_snapshot.json"
    tf state pull > "$snapshot" 2>/dev/null || die_status state_reconciliation_failed "state pull failed"
    chmod 0600 "$snapshot"
    SUMMARY_CLEANUP_STATE="kept"
    if ! tf import "$ROLE_TF_ADDR" "$TARGET_ROLE" >/dev/null 2>&1; then
        SUMMARY_STATE_RECONCILIATION="rolled_back"
        tf state rm "$ROLE_TF_ADDR" >/dev/null 2>&1 || true
        die_status state_reconciliation_failed "terraform import failed; rolled the address back out of state"
    fi
}

# A refusal AFTER we imported the role address must leave Terraform state as we
# found it: roll the freshly-imported address back out so a rejected plan never
# leaves a half-reconciled state behind. Only the address we added is removed,
# returning state to its pre-import lineage/serial+1; the 0600 state snapshot is
# retained as the rollback audit trail. No-op when no import was performed.
refuse_post_import() {
    local status="$1" msg="$2"
    if [ "$SUMMARY_STATE_RECONCILIATION" = "performed" ]; then
        tf state rm "$ROLE_TF_ADDR" >/dev/null 2>&1 || true
        SUMMARY_STATE_RECONCILIATION="rolled_back"
    fi
    die_status "$status" "$msg"
}

run_guarded_apply() {
    # Backend key must match ops/iam/backend.tf ("iam/terraform.tfstate") so the
    # guarded rollout drives the canonical IAM remote state object, not a
    # sibling; a wrong key silently forks state and lets apply "succeed" against
    # a stale/empty backend.
    tf init -input=false -reconfigure \
        -backend-config="bucket=$TFSTATE_BUCKET" \
        -backend-config="key=iam/terraform.tfstate" \
        -backend-config="region=$REGION" >/dev/null 2>&1 \
        || die_status terraform_init_failed "terraform init against $TFSTATE_BUCKET failed"

    reconcile_role_state_if_needed

    local plan_file="$ARTIFACT_DIR/plan.bin" rc=0
    tf plan -input=false -detailed-exitcode -out="$plan_file" >/dev/null 2>&1 || rc=$?
    [ -f "$plan_file" ] || refuse_post_import plan_not_saved "terraform plan produced no saved plan file"

    case "$rc" in
        0)
            [ "$SUMMARY_POLICY_MATCH" = "exact" ] \
                || refuse_post_import unsafe_plan_refused "plan reports no change but live policy is not the exact shape"
            SUMMARY_APPLY_METHOD="already_current"
            SUMMARY_PLAN_DENOMINATOR="0"
            SUMMARY_PLAN_ACTIONS="[]"
            ;;
        2)
            local show_json analysis denom actions safe
            show_json="$(tf show -json "$plan_file" 2>/dev/null)" \
                || refuse_post_import plan_show_failed "terraform show -json failed"
            analysis="$(printf '%s' "$show_json" | py analyze-plan)"
            denom="$(printf '%s' "$analysis" | cut -f1)"
            actions="$(printf '%s' "$analysis" | cut -f2)"
            safe="$(printf '%s' "$analysis" | cut -f3)"
            SUMMARY_PLAN_DENOMINATOR="$denom"
            SUMMARY_PLAN_ACTIONS="$actions"
            [ "$safe" = "1" ] || refuse_post_import unsafe_plan_refused \
                "saved plan changes $denom resources / actions $actions; only one $INLINE_POLICY_NAME create|update is allowed"
            tf apply -input=false "$plan_file" >/dev/null 2>&1 \
                || refuse_post_import terraform_apply_failed "terraform apply of the saved plan failed"
            SUMMARY_APPLY_METHOD="terraform_apply"
            if [ "$SUMMARY_STATE_RECONCILIATION" = "performed" ]; then
                SUMMARY_APPLY_METHOD="state_reconciled_apply"
            fi
            ;;
        *)
            refuse_post_import unsafe_plan_refused "terraform plan returned rc=$rc (neither no-change nor a clean single-resource change)"
            ;;
    esac
}

if [ "$VERIFY_ONLY" = "true" ]; then
    SUMMARY_APPLY_METHOD="verify_only"
else
    run_guarded_apply
fi

# ==========================================================================
# Phase 5 — On-host least-privilege API probes (retry only AccessDenied)
# ==========================================================================
PROBE_RESULT=""
PROBE_OUTPUT=""
run_probe() {
    local cmd="$1" key="$2" attempt=0 out rc err errfile
    errfile="$(mktemp)"
    PROBE_RESULT="denied"; PROBE_OUTPUT=""
    while [ "$attempt" -lt "$PROBE_MAX_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -gt "$SUMMARY_PROPAGATION_ATTEMPTS" ] && SUMMARY_PROPAGATION_ATTEMPTS="$attempt"
        out="$("$SSM_EXEC" "$cmd" 2>"$errfile")"; rc=$?
        err="$(cat "$errfile")"
        if [ "$rc" -eq 0 ] && printf '%s' "$out" | py has-key "$key"; then
            PROBE_RESULT="ok"; PROBE_OUTPUT="$out"; break
        fi
        if printf '%s%s' "$out" "$err" | grep -q "AccessDeniedException"; then
            PROBE_RESULT="denied"
            [ "$attempt" -lt "$PROBE_MAX_ATTEMPTS" ] && sleep "$PROBE_SLEEP_SECONDS"
            continue
        fi
        PROBE_RESULT="error"; PROBE_OUTPUT="$err"; break
    done
    rm -f "$errfile"
}

finish_denied_or_error() {
    # $1 = probe status var value already set; decide terminal status.
    case "$1" in
        denied) die_status persistent_authorization_denial \
            "least-privilege policy is intact but the read grant has not propagated after $SUMMARY_PROPAGATION_ATTEMPTS attempts" ;;
        *) die_status probe_failed "an API probe failed for a non-authorization reason" ;;
    esac
}

run_probe "$(shell_join_for_exec \
    aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --region "$REGION" \
    --output json)" "logGroups"
SUMMARY_PROBE_DLG="$PROBE_RESULT"
[ "$PROBE_RESULT" = "ok" ] || finish_denied_or_error "$PROBE_RESULT"

run_probe "$(shell_join_for_exec \
    aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --limit 1 \
    --region "$REGION" \
    --output json)" "events"
SUMMARY_PROBE_FLE="$PROBE_RESULT"
[ "$PROBE_RESULT" = "ok" ] || finish_denied_or_error "$PROBE_RESULT"

run_probe "$(shell_join_for_exec \
    aws logs describe-log-streams \
    --log-group-name "$LOG_GROUP" \
    --order-by LastEventTime \
    --descending \
    --limit 5 \
    --region "$REGION" \
    --output json)" "logStreams"
SUMMARY_PROBE_DLS="$PROBE_RESULT"
[ "$PROBE_RESULT" = "ok" ] || finish_denied_or_error "$PROBE_RESULT"
stream_fields=()
read_py_lines stream_fields "$PROBE_OUTPUT" parse-streams
SUMMARY_STREAM_DENOMINATOR="${stream_fields[0]:-0}"
selected_stream="${stream_fields[1]:-}"
[ "$SUMMARY_STREAM_DENOMINATOR" -ge 1 ] 2>/dev/null \
    || die_status probe_failed "describe-log-streams returned no streams to sample"

run_probe "$(shell_join_for_exec \
    aws logs get-log-events \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "$selected_stream" \
    --limit 1 \
    --region "$REGION" \
    --output json)" "events"
SUMMARY_PROBE_GLE="$PROBE_RESULT"
[ "$PROBE_RESULT" = "ok" ] || finish_denied_or_error "$PROBE_RESULT"

# ==========================================================================
# Phase 6 — Finalize (secure cleanup of rollback-only files, then summary)
# ==========================================================================
if [ "$SUMMARY_CLEANUP_STATE" = "kept" ]; then
    # Reconciliation proof passed: the state snapshot was a rollback aid only.
    rm -f "$ARTIFACT_DIR/state_snapshot.json"
    SUMMARY_CLEANUP_STATE="deleted"
fi

if [ "$VERIFY_ONLY" = "true" ]; then
    SUMMARY_STATUS="verify_only_complete"
else
    SUMMARY_STATUS="success"
fi
write_summary
echo "$SUMMARY_STATUS: probes ok (streams=$SUMMARY_STREAM_DENOMINATOR, attempts=$SUMMARY_PROPAGATION_ATTEMPTS); summary at $ARTIFACT_DIR/summary.json"
exit 0
