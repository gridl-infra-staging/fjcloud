#!/usr/bin/env bash
# Provision an ephemeral Linux devbox for fjcloud's LOCAL-phase test suites.
#
# WHY THIS EXISTS
#   The local phase (see docs/launch/beta_launch_remaining_work.md § "What has to
#   be true to end the local phase") is gated on the browser suite and on
#   `scripts/local-ci.sh --fast`. Both run on the operator's Mac, and --fast
#   takes a repo-wide lock (scripts/lib/local_ci_fast_lock.sh), so concurrent
#   workers serialise behind one ~21-minute gate. Moving those runs to a
#   dedicated Linux box removes the contention and — because production is x86
#   Linux — measures on an architecture closer to prod than darwin/arm64 is.
#
# WHAT THIS BOX DELIBERATELY DOES NOT GET
#   No IAM instance profile, and therefore no AWS credentials of any kind.
#   The local phase needs postgres + docker + the flapjack binary and nothing
#   else, so a role would widen the credential blast radius to buy nothing —
#   and ROADMAP.md still carries an OPEN P0 for credentials exposed through the
#   public mirror. The ABSENCE of --iam-instance-profile below is a security
#   property, asserted by scripts/tests/devbox_provision_test.sh.
#
# PUBLIC MIRROR
#   scripts/ syncs wholesale to the public mirror per .debbie.toml, so this file
#   is published. Everything environment-specific is a flag or an env var; no
#   account ids, IPs, key names, or credentials may be hardcoded here.
#
# USAGE
#   provision_devbox.sh --name <name> --ssh-cidr <cidr> [options]
#   provision_devbox.sh --name <name> --terminate
#
#   --name <name>          devbox identity; also the Name-tag suffix
#   --ssh-cidr <cidr>      REQUIRED. Source range allowed to reach port 22.
#                          World-open ranges are refused (see below).
#   --key-name <name>      EC2 key pair for SSH. Default: $DEVBOX_KEY_NAME.
#   --instance-type <t>    Default: c7i.4xlarge (browser suite is CPU-bound).
#   --region <r>           Default: $AWS_DEFAULT_REGION.
#   --arch <x86_64|arm64>  Default: x86_64, matching production.
#   --dry-run              Print the plan; issue no mutating AWS call.
#   --terminate            Tear the devbox down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_PATH="$SCRIPT_DIR/cloud_init.yaml"

# Tag convention is inherited from scripts/validate_vm_autorepair_detection.sh:340
# so existing tag-based inventory and cleanup tooling can see this instance
# rather than treating it as an unattributed orphan.
TAG_MANAGED_BY="managed-by,Value=fjcloud"
TAG_STAGE_VALUE="devbox"

NAME=""
SSH_CIDR=""
KEY_NAME="${DEVBOX_KEY_NAME:-}"
INSTANCE_TYPE="c7i.4xlarge"
REGION="${AWS_DEFAULT_REGION:-}"
ARCH="x86_64"
DRY_RUN=0
TERMINATE=0

# `refuse` is the single exit path for every precondition failure. The
# DEVBOX_REFUSED: prefix is machine-readable on purpose: the test suite binds to
# it so that "script refused for reason X" cannot be confused with "script was
# missing" or "bash blew up", both of which also exit non-zero.
refuse() {
    echo "DEVBOX_REFUSED: $*" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)          NAME="${2:-}"; shift 2 ;;
        --ssh-cidr)      SSH_CIDR="${2:-}"; shift 2 ;;
        --key-name)      KEY_NAME="${2:-}"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="${2:-}"; shift 2 ;;
        --region)        REGION="${2:-}"; shift 2 ;;
        --arch)          ARCH="${2:-}"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --terminate)     TERMINATE=1; shift ;;
        *) refuse "unknown argument '$1'" ;;
    esac
done

[ -n "$NAME" ]   || refuse "--name is required"
[ -n "$REGION" ] || refuse "--region or AWS_DEFAULT_REGION is required"

DEVBOX_NAME="fjcloud-devbox-$NAME"

# Every AWS call goes through this wrapper so --region is applied in exactly one
# place and the call shape stays uniform.
aws_ec2() { aws ec2 "$@" --region "$REGION"; }

# Discover this devbox by BOTH its Name tag and the stage tag. Filtering on the
# stage tag as well is what keeps --terminate from ever matching a production
# instance that happens to share a name prefix.
#
# `stopped` is in the state filter because the idle auto-stop in cloud_init.yaml
# makes it the NORMAL resting state of an unattended devbox. Matching only
# running instances would make every reuse lookup miss, and each miss would
# launch a duplicate — which costs strictly more than not auto-stopping at all.
#
# Emits "<instance-id><TAB><state>" (empty when nothing matches).
find_instance() {
    aws_ec2 describe-instances \
        --filters "Name=tag:Name,Values=$DEVBOX_NAME" \
                  "Name=tag:stage,Values=$TAG_STAGE_VALUE" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
        --output text
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
if [ "$TERMINATE" -eq 1 ]; then
    existing="$(find_instance | awk 'NR==1{print $1}')"
    if [ -z "$existing" ]; then
        # Not an error: teardown is idempotent so it can be run unconditionally
        # from a cleanup path without the caller first checking for existence.
        echo "DEVBOX_TERMINATED=none (no running devbox named $DEVBOX_NAME)"
        exit 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY-RUN: would terminate $existing"
        exit 0
    fi
    aws_ec2 terminate-instances --instance-ids "$existing" >/dev/null
    echo "DEVBOX_TERMINATED=$existing"
    exit 0
fi

# ---------------------------------------------------------------------------
# Provision preconditions
# ---------------------------------------------------------------------------
[ -n "$SSH_CIDR" ] || refuse "--ssh-cidr is required (no default: an implicit default is how world-open rules get created by accident)"

# ROADMAP.md carries an OPEN P0 for a world-open tcp/7700 ingress rule that
# outlived its justification. Refusing the world-open forms here is what stops
# this script from opening a second one on a host holding the source tree.
case "$SSH_CIDR" in
    "0.0.0.0/0"|"::/0")
        refuse "--ssh-cidr $SSH_CIDR is world-open; pass your own address as a /32 (IPv4) or /128 (IPv6)" ;;
esac

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
SG_NAME="$DEVBOX_NAME-sg"

# NOTE ON THE "None" LITERAL: `--output text` renders a JMESPath scalar that
# resolves to null as the four-character string "None", not as an empty string.
# Treating that as a real group id would produce calls against a group named
# "None". Normalising it to empty here is the whole reason the test suite has
# test_treats_none_scalar_as_absent_security_group.
existing_sg="$(aws_ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text | tr -d '[:space:]')"
[ "$existing_sg" = "None" ] && existing_sg=""

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<PLAN
DRY-RUN plan for $DEVBOX_NAME
  region          $REGION
  instance type   $INSTANCE_TYPE ($ARCH)
  ssh ingress     $SSH_CIDR
  security group  ${existing_sg:-<would create $SG_NAME>}
  instance role   <none by design: the devbox holds no AWS credentials>
  cloud-init      $CLOUD_INIT_PATH
PLAN
    exit 0
fi

if [ -n "$existing_sg" ]; then
    SG_ID="$existing_sg"
else
    SG_ID="$(aws_ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "fjcloud devbox $NAME (local-phase test runner)" \
        --query 'GroupId' --output text | tr -d '[:space:]')"
    aws_ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr "$SSH_CIDR" >/dev/null
fi

# ---------------------------------------------------------------------------
# Reuse before launch
# ---------------------------------------------------------------------------
# Re-running this script is the normal way to get the devbox's address back.
# Launching a duplicate instead would silently double the hourly spend and leave
# an orphan that only tag-sweeping would ever find.
found="$(find_instance)"
existing="$(printf '%s' "$found" | awk 'NR==1{print $1}')"
existing_state="$(printf '%s' "$found" | awk 'NR==1{print $2}')"
if [ -n "$existing" ]; then
    # The idle auto-stop means "stopped" is the expected resting state, not an
    # error condition — bring it back up rather than reporting an unusable box.
    case "$existing_state" in
        stopped|stopping)
            aws_ec2 start-instances --instance-ids "$existing" >/dev/null
            echo "DEVBOX_RESTARTED=1" ;;
    esac
    echo "DEVBOX_INSTANCE_ID=$existing"
    echo "DEVBOX_REUSED=1"
    exit 0
fi

# Canonical's owner id (099720109477) is a well-known public constant, not a
# secret, and pinning it stops a look-alike AMI published under a similar name
# from being selected.
AMI_ID="$(aws_ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-*-server-*" \
              "Name=architecture,Values=$ARCH" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text | tr -d '[:space:]')"
[ -n "$AMI_ID" ] && [ "$AMI_ID" != "None" ] || refuse "no Ubuntu 24.04 $ARCH AMI found in $REGION"

launch_args=(
    --image-id "$AMI_ID"
    --instance-type "$INSTANCE_TYPE"
    --security-group-ids "$SG_ID"
    --user-data "file://$CLOUD_INIT_PATH"
    # IMDSv2 required, matching the launch convention already used by
    # scripts/validate_vm_autorepair_detection.sh. Instance metadata tags stay
    # off: nothing on this box reads them.
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=120,VolumeType=gp3,DeleteOnTermination=true}"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$DEVBOX_NAME},{Key=$TAG_MANAGED_BY},{Key=stage,Value=$TAG_STAGE_VALUE}]"
    --query 'Instances[0].InstanceId'
    --output text
)
# Only pass --key-name when one was supplied; passing an empty value would make
# AWS reject the whole call with a confusing parameter error.
[ -n "$KEY_NAME" ] && launch_args+=(--key-name "$KEY_NAME")

# DELIBERATELY ABSENT: --iam-instance-profile. See the header. Do not add one
# without also updating scripts/tests/devbox_provision_test.sh, which fails if
# it reappears.
INSTANCE_ID="$(aws_ec2 run-instances "${launch_args[@]}" | tr -d '[:space:]')"

echo "DEVBOX_INSTANCE_ID=$INSTANCE_ID"
echo "DEVBOX_SECURITY_GROUP=$SG_ID"
echo "DEVBOX_REUSED=0"
