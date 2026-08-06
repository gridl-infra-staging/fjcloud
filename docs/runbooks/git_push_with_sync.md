# git push with mirror sync

`scripts/git_push_with_sync.sh` is the repo-owned wrapper for pushing from the dev repo while keeping `git push` as the authoritative action.

## Invocation

Run the wrapper exactly like `git push`; all arguments are forwarded unchanged.

```bash
bash scripts/git_push_with_sync.sh origin main
bash scripts/git_push_with_sync.sh origin HEAD:main --force-with-lease
```

## Contract

- `git push` is authoritative: the wrapper returns the same `git push` exit behavior.
- Mirror sync runs only when the current branch is `main`.
- On `main`, `debbie sync staging` runs after a successful push. Staging tracks dev main continuously — it is the environment that soaks every commit.
- `debbie sync prod` does **not** run by default. Prod promotion is a deliberate, gated step (see below). Set `PROD_SYNC=1` to include prod in this push's sync anyway; when set, sync order is fixed: staging then prod.
- Set `SKIP_DEBBIE_SYNC=1` to opt out of all mirror sync for a push.
- Set `DEBBIE_BIN=/abs/path/to/debbie` when `debbie` is not on `PATH`.
- Mirror sync is best-effort: sync failures emit warnings and do not replace a successful `git push` outcome.

## Prod promotion (gated)

The one canonical prod-promotion verb is:

```bash
bash scripts/launch/post_wave_a_sync_prod.sh --execute --yes
```

It refuses to sync unless the staging mirror has validated exactly what would ship: staging was synced from the current dev HEAD SHA (checked against debbie's `.debbie/sync_manifest.json` provenance record — an exact SHA match, not a timestamp heuristic), and staging CI is green at the staging mirror HEAD (a single run conclusion covers every job, including the post-deploy `e2e-deployed` verification that prod CI does not run). After syncing it polls prod mirror CI and runs the deploy-verify test.

**Cadence:** promote at every orchestration wave boundary, and at least daily during active development — daily keeps healthy operation inside the deploy-currency drift alarm's 24h page threshold, so a page always means a genuinely stalled pipeline, never a quiet day.

There is deliberately no gate-bypass flag. For a genuine emergency, run `debbie sync prod` directly — that keeps the bypass loud and manual. That direct call still passes through the publish guard below, so it ships whatever `main` currently is; it cannot ship an unmerged branch.

## The publish guard (applies to every sync path)

`scripts/lib/publish_guard.sh` is sourced by `.debbie/post-sync.sh` and therefore runs for **every** caller — the wrapper above, `post_wave_a_sync_prod.sh`, and a bare `debbie sync <target>` typed by a lane. It refuses to publish unless `HEAD` in the invoking dev root is reachable from `origin/main`, and it refuses *before* the mirror commit is created, so a rejected sync never reaches the public remote.

Both mirrors are public repositories, and `debbie sync` accepts no source ref — it stamps `git rev-parse HEAD` at whatever root it was invoked from. Without this guard a matt lane, whose root is a worktree pinned to `batman/<lane>`, can only ever publish its own unmerged branch. That happened on 2026-08-05: the staging mirror manifest recorded `dev_sha=695505c76b2c...`, a commit on no other ref.

What the single ancestry check decides:

| Invoking dev root | Verdict |
| --- | --- |
| `main`, pushed | publish |
| `main`, commits not yet pushed | refuse — the stamped `dev_sha` would name a commit nobody else can resolve |
| a `batman/<lane>` branch | refuse — unmerged code must not reach a public mirror |
| detached HEAD at a pushed `origin/main` SHA | publish — this is the supported deploy-from-a-lane recipe below |

A refusal exits `3`, prints both remedies, and restores the mirror working tree to its last published commit. That restore is load-bearing rather than tidiness: debbie has already copied the dev tree over the mirror by the time the hook runs, the publish step is `git add -A`, and debbie's prune only considers *tracked* paths — so an untracked file left behind by a refused sync would be committed and published by the next legitimate sync. Restoring is safe because the mirror is a derived, debbie-owned target whose only source of truth is the dev repo.

### Deploying from inside a lane

A lane cannot publish its own branch, and it cannot merge itself to `main` from its worktree. To publish current `main` from inside a lane, sync from a throwaway worktree checked out at the pushed SHA:

```bash
git fetch origin main
git worktree add /tmp/fjcloud-publish "$(git rev-parse origin/main)"
cd /tmp/fjcloud-publish && debbie sync staging
```

This is the shape the 2026-07-24 staging billing rehearsal used for the last sync that satisfied the ancestry gate. A lane whose *own* fixes must be deployed has to merge first — that sync belongs to whoever lands the merge, not to the lane.

### Override

`FJCLOUD_ALLOW_UNMERGED_PUBLISH=1` skips the check. It warns on stderr and names the exact SHA it let through, so the bypass is legible in any captured log. It exists so the guard gets overridden deliberately in an emergency rather than deleted; there is no legitimate routine use.

### There are two layers here, and that is deliberate

`debbie` enforces the same rule itself, as of 2026-08-05 (`mike_dev/tools/debbie`, `assert_dev_head_is_published`). Debbie's check is the better of the two and normally the only one that fires: it runs *before* debbie copies anything, so a refused sync leaves the mirror untouched, and it protects every repo debbie serves rather than this one.

The repo-local hook guard is kept anyway because **fjcloud does not pin debbie's version**. Debbie is a separately installed CLI; a rollback, an older machine, or a reinstall from an earlier ref would silently remove the only protection this repo has. The hook is the part of the rule fjcloud controls, and it travels with the checkout.

They are not duplicates — they refuse at different moments and for different blast radii. Do not delete one as redundant without checking the other still covers the case you care about. Note that a deliberate override now needs **both** switches: `DEBBIE_ALLOW_UNPUBLISHED_SYNC=1` for debbie's, then `FJCLOUD_ALLOW_UNMERGED_PUBLISH=1` for this one.

## Why no client-side post-push hook

This repo does not use a client-side post-push hook for mirror sync ownership. The wrapper keeps one explicit, repo-owned procedure in `docs/runbooks/` and avoids introducing a second publish path.
