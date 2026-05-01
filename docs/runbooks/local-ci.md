# local-ci — pre-push gate mirror

`scripts/local-ci.sh` runs every gate the staging `deploy-staging` job depends on, locally and in parallel. **Use it before every push to `main`** so you catch the cheap failures (formatter, file sizes, lint, static contract tests, secret scan) in seconds instead of waiting ~15 minutes for the staging CI cycle.

## Why this exists

The staging→prod debbie sync flow runs all CI gates in GitHub Actions. A single CI cycle takes ~15 minutes — and with the deploy gate's `needs[]` list, ANY failing dependency cancels the deploy. Real failures from this session that local-ci would have caught in seconds:

- `cargo fmt --check` formatting violations on freshly added test code
- `scripts/check-sizes.sh` exceeding the 1300-line hard limit on `webhooks.rs` after inline tests pushed it past the threshold
- `scripts/tests/screen_specs_coverage_test.sh` missing-route catches
- `scripts/tests/ses_iam_configset_coupling_test.sh` IAM/code-coupling regressions

The cost asymmetry is severe: ~20s local vs. ~15min CI. Every "I'll just push and let CI tell me" is a 45x slowdown for issues that are deterministic locally.

## Modes

```bash
bash scripts/local-ci.sh                # default: --fast
bash scripts/local-ci.sh --fast         # skip cargo workspace test (default; runs in ~20s)
bash scripts/local-ci.sh --full         # include cargo test --workspace (5-10 min cold, 1-2 min cached)
bash scripts/local-ci.sh --gate <name>  # run only one gate
bash scripts/local-ci.sh --help         # full help
```

Available gate names: `rust-test`, `rust-lint`, `migration-test`, `web-test`, `check-sizes`, `web-lint`, `secret-scan`.

## Gate-by-gate mapping to CI

Each local gate is the line-for-line equivalent of its CI counterpart, with documented divergences where the local form differs:

| Gate | CI command | Local form | Divergence note |
|---|---|---|---|
| `rust-lint` | `ci_workflow_test` + email seams + `cargo fmt --check` + `cargo clippy --workspace -- -D warnings` | identical | none |
| `rust-test` | `cargo test --workspace -j 1` + tenant isolation proptest | drops `-j 1` | `-j 1` is a CI-runner RAM tradeoff irrelevant locally |
| `migration-test` | `sqlx migrate run` against postgres service container | same `sqlx migrate run` against local postgres | SKIP if no local postgres / sqlx-cli (with remediation hint) |
| `web-test` | `npm ci && npm test` | `npm test` after a stale-lockfile check | if `web/package-lock.json` is newer than `web/node_modules/.package-lock.json`, FAIL with remediation — closes the false-pass gap where CI's `npm ci` would have caught a stale local install |
| `web-lint` | `npm run check` + `eslint .` + `lint:e2e` + `screen_specs_coverage_test` + `ses_iam_configset_coupling_test` | identical (with the same stale-lockfile check) | none |
| `check-sizes` | `bash scripts/check-sizes.sh` | identical | none |
| `secret-scan` | `gitleaks detect --redact -v --exit-code=2` | `scripts/reliability/lib/security_checks.sh::check_secret_scan` | uses the repo's reliability secret scan instead of gitleaks; SSOT-aligned with the broader reliability gate |

## SKIP semantics

A SKIP is **not** a silent pass. The script exits 0 only because your local environment couldn't satisfy a prereq (e.g. no `sqlx-cli`, no postgres on `127.0.0.1:5432`) — but the SKIP banner names the missing prereq with the exact remediation command. Compare to a FAIL which means your code broke something.

The script distinguishes between **missing tool** ("install sqlx-cli") and **service unreachable** ("start postgres"), since they need different fixes. Postgres reachability is probed via bash's built-in `/dev/tcp` so the probe itself has no install dependency.

## Where logs live

Per-gate stdout+stderr is captured during the run. After the script exits, all logs are moved to `${TMPDIR:-/tmp}/local-ci-last-logs/<gate>.log` and persist until the next `local-ci.sh` invocation, which clears the directory and re-populates it. The log paths printed in the summary table point at this persisted location, so they remain readable for as long as you're investigating the run.

## When to use which mode

- **Tight inner loop** while iterating on one crate or one file: use the relevant single-purpose `cargo check -p <crate>` / `npx vitest run path/to/test.ts` etc. (still listed in CLAUDE.md). local-ci is for the gate-level confidence check.
- **Before pushing to `main`**: `bash scripts/local-ci.sh` (fast mode). This catches almost every CI failure class.
- **Before pushing a non-trivial Rust change**: add `--full` so the workspace tests run too.
- **Investigating why CI failed last cycle**: use `--gate <name>` to reproduce just that gate.

## Maintenance

When the staging `.github/workflows/ci.yml` adds, removes, or changes the `deploy-staging` `needs[]` list, mirror the change in `scripts/local-ci.sh`'s `schedule` block and add/remove the corresponding gate function. Each gate function is a short bash function so the mirror stays cheap to keep in sync. The CI workflow file and the local script live in the same repo and ship together via debbie.
