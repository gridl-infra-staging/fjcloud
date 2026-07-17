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

There is deliberately no gate-bypass flag. For a genuine emergency, run `debbie sync prod` directly — that keeps the bypass loud and manual.

## Why no client-side post-push hook

This repo does not use a client-side post-push hook for mirror sync ownership. The wrapper keeps one explicit, repo-owned procedure in `docs/runbooks/` and avoids introducing a second publish path.
