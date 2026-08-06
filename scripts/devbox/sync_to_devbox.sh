#!/usr/bin/env bash
# Push the working tree to the devbox, without pushing credentials to it.
#
# WHY RSYNC AND NOT `git clone` ON THE BOX
#   Cloning would need git credentials for a private repo, which means putting a
#   credential on a host that provision_devbox.sh deliberately launches with no
#   IAM role and no secrets. Pushing from the operator's machine keeps every
#   credential on this side of the connection. It also syncs uncommitted work,
#   which is what a test-runner box actually needs.
#
# WHAT MUST NEVER CROSS
#   `.secret/` holds the static AWS IAM keys, Stripe keys, OAuth secrets and the
#   devbox private key itself. Sending it would hand the box the entire
#   credential set in one step and undo the no-role design. That exclusion is
#   behaviour-tested in scripts/tests/devbox_sync_test.sh against a real rsync
#   run, not asserted by grepping this file for a flag.
#
# USAGE
#   sync_to_devbox.sh --dest ubuntu@<host>:/home/ubuntu/fjcloud_dev --key <pem>
#   sync_to_devbox.sh --source <dir> --dest <any rsync destination> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SOURCE="$REPO_ROOT"
DEST=""
SSH_KEY=""
DRY_RUN=0
# Caller-supplied excludes, appended AFTER the built-in ones so they can add to
# the exclusion set but never subtract from it — the credential exclusions are
# not negotiable by a caller.
EXTRA_EXCLUDES=()

# Single exit path for precondition failures. The DEVBOX_REFUSED: prefix is
# machine-readable so tests can tell "refused for reason X" apart from "the
# script blew up", which also exits non-zero.
refuse() {
    echo "DEVBOX_REFUSED: $*" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --source)  SOURCE="${2:-}"; shift 2 ;;
        --dest)    DEST="${2:-}"; shift 2 ;;
        --key)     SSH_KEY="${2:-}"; shift 2 ;;
        --exclude) EXTRA_EXCLUDES+=(--exclude="${2:-}"); shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) refuse "unknown argument '$1'" ;;
    esac
done

[ -n "$DEST" ] || refuse "--dest is required (e.g. ubuntu@<host>:/home/ubuntu/fjcloud_dev)"
[ -d "$SOURCE" ] || refuse "--source '$SOURCE' is not a directory"

# Exclusions fall into two groups with different reasons, kept separate so a
# future edit does not treat them as interchangeable:
#
#   1. CREDENTIALS — must never cross, at any path depth. Unanchored so a
#      nested .secret/ is caught too.
#   2. BUILD ARTEFACTS — gigabytes, and the Mac's are the wrong architecture for
#      a Linux box regardless. Excluding them is what makes the sync quick
#      enough to run on every iteration.
EXCLUDES=(
    # 1. credentials
    --exclude=.secret
    --exclude=.env.secret
    --exclude=*.pem
    # 2. build artefacts
    --exclude=node_modules
    --exclude=target
    --exclude=.svelte-kit
    --exclude=build
    --exclude=dist
    --exclude=test-results
    # 3. ORCHESTRATION SCRATCH — matt/batman lane state and logs. Not needed to
    #    run any test, and a live sync found an AWS-shaped access key id sitting
    #    in one of these logs, which has no business on a box built to hold no
    #    credential material.
    --exclude=.mike
    # 4. GENERATED LOCAL ENV — .env.local is built from the operator's secret
    #    file and can hold live infrastructure credentials. It is gitignored,
    #    but rsync does not consult .gitignore. The box runs
    #    scripts/bootstrap-env-local.sh itself to get template defaults, which
    #    is all the local phase needs.
    --exclude=.env.local
    --exclude=playwright-report
    --exclude=.git/objects
    # 5. DESTINATION-OWNED RUNTIME STATE — Playwright's setup projects write
    #    storage state to web/tests/fixtures/.auth/ ON THE BOX. It is gitignored
    #    (web/.gitignore:26) so it never exists here, which means --delete would
    #    remove it from the box on every sync. A sync landing during a live run
    #    therefore pulled the auth state out from under it: three consecutive
    #    runs scored 201-243 instead of 334, all failing on
    #    `ENOENT tests/fixtures/.auth/*.json` while every setup project still
    #    reported passed. That reads as a product regression and is not one.
    #    Excluding it is what protects it, since --delete spares excluded paths.
    --exclude=.auth
    --exclude=_local_ci_set_e_regression_fixture.*.rs
)

rsync_args=(-a --delete "${EXCLUDES[@]}" ${EXTRA_EXCLUDES+"${EXTRA_EXCLUDES[@]}"})

# --delete keeps the box from accumulating files deleted locally. rsync does NOT
# delete excluded paths under plain --delete (that would need --delete-excluded),
# so the box's own node_modules and target dirs survive between syncs — which is
# the whole point of excluding them.

if [ "$DRY_RUN" -eq 1 ]; then
    # -n never writes; -i itemises each candidate so tests can assert on what
    # would actually move rather than on this script's flags.
    rsync_args+=(-n -i)
fi

# Only build an -e transport when the destination is remote. A local dest (used
# by the test suite, and handy for staging a copy) must not require a key.
if [ -n "$SSH_KEY" ] && [[ "$DEST" == *:* ]]; then
    rsync_args+=(-e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR")
fi

# Trailing slash on the source: copy the CONTENTS of the tree into dest, rather
# than nesting the source directory inside it.
exec rsync "${rsync_args[@]}" "$SOURCE/" "$DEST"
