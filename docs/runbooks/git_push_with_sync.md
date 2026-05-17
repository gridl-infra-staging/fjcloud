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
- On `main`, sync order is fixed: `debbie sync staging` then `debbie sync prod`.
- Set `SKIP_DEBBIE_SYNC=1` to opt out of mirror sync for a push.
- Mirror sync is best-effort: sync failures emit warnings and do not replace a successful `git push` outcome.

## Why no client-side post-push hook

This repo does not use a client-side post-push hook for mirror sync ownership. The wrapper keeps one explicit, repo-owned procedure in `docs/runbooks/` and avoids introducing a second publish path.
