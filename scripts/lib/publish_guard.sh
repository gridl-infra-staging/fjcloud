#!/usr/bin/env bash
# Refuse to publish a dev tree that origin/main cannot vouch for.
#
# WHY THIS EXISTS (anchored 2026-08-05)
# -------------------------------------
# `debbie sync <target>` takes no source ref. It stamps the mirror's
# `.debbie/sync_manifest.json` with `git rev-parse HEAD` resolved at
# `git rev-parse --show-toplevel` of wherever it was invoked (debbie
# sync.py:141 and 382-391). A matt lane runs inside a linked worktree pinned to
# its own `batman/<lane>` branch, so a lane can only ever stamp its own branch
# tip — and both fjcloud mirrors are PUBLIC repositories.
#
# On 2026-08-05 the staging-deploy lane synced the public staging mirror from
# `batman/aug05_2am_6_staging_deploy_and_proof_refresh`. The mirror manifest
# recorded `dev_sha=695505c76b2c...`, a commit on no other ref. Two consequences,
# both real:
#
#   1. Unmerged code reaches a public mirror and gets deployed from there. The
#      published tree never passed through main.
#   2. Every downstream gate that asserts `git merge-base --is-ancestor
#      "$dev_sha" origin/main` becomes unsatisfiable, because the branch merges
#      only after the lane that would assert it has ended. Lanes wrote that
#      assertion into their own exit conditions and then could not discharge it.
#
# `scripts/git_push_with_sync.sh` already declines to sync off `main`, but that
# guard lives in one caller. Calling `debbie sync` directly — which is what lane
# checklists instruct — bypasses it entirely. This file moves the rule to the
# debbie post-sync hook, which runs for EVERY caller, so the guard belongs to
# the publish operation rather than to one path into it.
#
# WHY ANCESTRY IS THE WHOLE PREDICATE
# -----------------------------------
# A single `git merge-base --is-ancestor HEAD origin/main` classifies all four
# real cases correctly, which is why there is no branch-name check here:
#
#   on main, pushed            -> ancestor      -> allow
#   on main, not yet pushed    -> NOT ancestor  -> refuse (the manifest would
#                                                  name a commit no one else
#                                                  can resolve)
#   on a batman/<lane> branch  -> NOT ancestor  -> refuse (the 2026-08-05 case)
#   detached at a pushed SHA   -> ancestor      -> allow (this is the supported
#                                                  deploy-from-a-lane recipe:
#                                                  `git worktree add <path>
#                                                  <origin/main sha>`, then sync
#                                                  from there)
#
# Checking the branch name instead would wrongly reject that last row, which is
# the only correct way a lane can publish at all.
#
# WHY THIS DOES NOT FETCH
# -----------------------
# The check reads the local `origin/main` remote-tracking ref and never touches
# the network. That keeps a hang out of the publication path, and it is safe in
# the direction that matters: `origin/main` only ever moves forward (barring a
# force-push to main, which shared-clone discipline already forbids), so a stale
# ref can only make ancestry HARDER to satisfy. A stale ref therefore produces a
# false refusal, never a false approval. The refusal message says to fetch.
#
# WHAT THIS DELIBERATELY DOES NOT CHECK
# -------------------------------------
# Debbie copies from the working tree, not from git, so uncommitted edits under
# a synced path are published too. That is a real and separate provenance hole;
# closing it needs the sync whitelist to decide which dirty paths matter, which
# is debbie's knowledge and not this guard's. Tracked as its own follow-up
# rather than silently widened into here.
#
# Contract:
#   assert_dev_head_is_publishable <dev_root>
#     returns 0 — HEAD is reachable from origin/main; safe to publish
#     returns 3 — refused; reason and remedies printed to stderr
#
# The refusal status is 3 specifically so callers and tests can tell a refusal
# apart from a missing file (127), a bash error (2), or a generic failure (1).
#
# WHY THE REFUSAL DOES NOT MENTION THE OVERRIDE
# ---------------------------------------------
# FJCLOUD_ALLOW_UNMERGED_PUBLISH=1 works, but the refusal message deliberately
# does not advertise it. Printed beneath the two legitimate remedies it reads as
# a third one, and an autonomous lane that has just been blocked will take the
# cheapest option offered. The remedies in the message are the two ways to
# publish CORRECTLY; the override is a way to publish incorrectly, so it is
# documented in docs/runbooks/git_push_with_sync.md for someone deliberately
# reading the contract, and nowhere in the blocked path.

# Distinct, greppable refusal status. See the note above.
PUBLISH_GUARD_REFUSED_STATUS=3

assert_dev_head_is_publishable() {
    local dev_root="${1:?assert_dev_head_is_publishable requires a dev repo root}"

    local head_sha=""
    local head_ref=""
    local origin_main_sha=""

    # Every git call below is `|| true`-guarded because this function is sourced
    # into scripts running `set -e` (.debbie/post-sync.sh does). Without that, a
    # failing probe would abort the caller before the guard could print its
    # explanation, turning a clear refusal into a bare non-zero exit.
    head_sha="$(git -C "$dev_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$head_sha" ]]; then
        echo "PUBLISH REFUSED: cannot resolve HEAD in dev root '$dev_root'." >&2
        echo "  Nothing is published when the source commit is unknown." >&2
        return "$PUBLISH_GUARD_REFUSED_STATUS"
    fi

    # The override is checked after HEAD resolves so the warning can name the
    # SHA it let through, and before any verdict so it cannot be pre-empted by
    # a refusal path returning first.
    if [[ "${FJCLOUD_ALLOW_UNMERGED_PUBLISH:-0}" == "1" ]]; then
        echo "WARNING: FJCLOUD_ALLOW_UNMERGED_PUBLISH=1 — publish guard bypassed." >&2
        echo "  Publishing $head_sha from '$dev_root' without proving it is reachable" >&2
        echo "  from origin/main. This may put unmerged code into a PUBLIC mirror." >&2
        return 0
    fi

    # `--abbrev-ref HEAD` prints the literal string "HEAD" for a detached
    # checkout. Render that as "detached HEAD" so the refusal message reads
    # correctly in the worktree case instead of claiming a branch named HEAD.
    head_ref="$(git -C "$dev_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -z "$head_ref" || "$head_ref" == "HEAD" ]]; then
        head_ref="detached HEAD"
    fi

    origin_main_sha="$(git -C "$dev_root" rev-parse --verify --quiet origin/main 2>/dev/null || true)"
    if [[ -z "$origin_main_sha" ]]; then
        # Indeterminate is not healthy. Without origin/main there is no way to
        # establish that HEAD is published, so this refuses rather than falling
        # through to an allow.
        echo "PUBLISH REFUSED: dev root '$dev_root' has no resolvable origin/main ref." >&2
        echo "  HEAD:   $head_sha ($head_ref)" >&2
        echo "  Remedy: git -C '$dev_root' fetch origin main, then retry." >&2
        return "$PUBLISH_GUARD_REFUSED_STATUS"
    fi

    if git -C "$dev_root" merge-base --is-ancestor "$head_sha" "$origin_main_sha" 2>/dev/null; then
        return 0
    fi

    # Refusal. The message has to be actionable by an agent with no operator to
    # ask, so it names both supported remedies explicitly.
    echo "PUBLISH REFUSED: HEAD is not reachable from origin/main, so it must not be published." >&2
    echo "  dev root:    $dev_root" >&2
    echo "  HEAD:        $head_sha ($head_ref)" >&2
    echo "  origin/main: $origin_main_sha" >&2
    echo "  Both fjcloud mirrors are PUBLIC and deploy from what is synced to them." >&2
    echo "  Publishing this tree would put code that never reached main into a public" >&2
    echo "  repository, and would stamp a dev_sha that no ancestry gate can satisfy." >&2
    echo "" >&2
    echo "  Remedy A — publish main (normal path):" >&2
    echo "    merge this work to main, then from the main clone on main run" >&2
    echo "    'bash scripts/git_push_with_sync.sh origin main'" >&2
    echo "  Remedy B — publish CURRENT MAIN from inside a lane." >&2
    echo "    This publishes origin/main. It does NOT include the unmerged work in" >&2
    echo "    this worktree, so it proves nothing about that work. Use it only when" >&2
    echo "    what you need deployed is already on main:" >&2
    echo "    git fetch origin main" >&2
    echo "    git worktree add <tmp path> \$(git rev-parse origin/main)" >&2
    echo "    cd <tmp path> && debbie sync <target>" >&2
    echo "  If origin/main simply looks stale here, 'git fetch origin main' and retry." >&2
    echo "  See docs/runbooks/git_push_with_sync.md." >&2

    return "$PUBLISH_GUARD_REFUSED_STATUS"
}
