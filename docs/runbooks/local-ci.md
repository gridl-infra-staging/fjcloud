# local-ci — pre-push gate mirror

`scripts/local-ci.sh` runs the locally mirrored staging `deploy-staging` dependency gates, in parallel where safe. **Use it before every push to `main`** so you catch the cheap failures (formatter, file sizes, lint, static contract tests, secret scan) before waiting for the staging CI cycle. The Rust test suite is not currently in the pre-push path when using the default `--fast` mode; run `--full` or `--gate rust-test` when you need that coverage.

## Why this exists

The staging→prod debbie sync flow runs CI gates in GitHub Actions. A single CI cycle takes ~15 minutes — and with the deploy gate's `needs[]` list, ANY failing dependency cancels the deploy. Real failures from this session that local-ci would have caught in seconds:

- `cargo fmt --check` formatting violations on freshly added test code
- `scripts/check-sizes.sh` exceeding the 1300-line hard limit on `webhooks.rs` after inline tests pushed it past the threshold
- `scripts/tests/screen_specs_coverage_test.sh` missing-route catches
- `scripts/tests/ses_iam_configset_coupling_test.sh` IAM/code-coupling regressions

The cost asymmetry is severe for the default fast checks: ~20s local vs. ~15min CI. Every "I'll just push and let CI tell me" is a 45x slowdown for issues that are deterministic locally, but `--fast` does not prove the Rust tests are green.

## Modes

```bash
bash scripts/local-ci.sh                # default: --fast
bash scripts/local-ci.sh --fast         # default; run mirrored fast gates, but not rust-test
bash scripts/local-ci.sh --full         # include cargo test --workspace (5-10 min cold, 1-2 min cached)
bash scripts/local-ci.sh --gate <name>  # run only one gate
bash scripts/local-ci.sh --with-contracts  # also run opt-in live contract probes
bash scripts/local-ci.sh --help         # full help
```

Available gate names include `rust-test`, `rust-lint`, `migration-test`, `web-test`, `check-sizes`, `web-lint`, and `secret-scan`; `scripts/local-ci.sh --help` is the owner for the full current list.

`--with-contracts` is intentionally separate from default CI gate mirroring. It runs live probes that touch external systems, including `scripts/canary/contracts/customer_loop_admin_cleanup_live_contract.sh`, which checks whether the current `/fjcloud/prod/admin_key` can satisfy `DELETE https://api.flapjack.foo/admin/tenants/00000000-0000-0000-0000-000000000000`.

When live prerequisites are missing (for example AWS auth or SSM access), contract probes print `SKIP:` remediation output instead of introducing a new default gate failure.

## Gate-by-gate mapping to CI

Each local gate is the line-for-line equivalent of its CI counterpart, with documented divergences where the local form differs:

| Gate | CI command | Local form | Divergence note |
|---|---|---|---|
| `rust-lint` | `ci_workflow_test` + email seams + `cargo fmt --check` + `cargo clippy --workspace -- -D warnings` | identical | none |
| `rust-test` | `cargo test --workspace` | identical | tenant isolation proptest moved to nightly workflow; no local/CI divergence in this gate |
| `migration-test` | `sqlx migrate run` against postgres service container | same `sqlx migrate run` against local postgres | SKIP if no local postgres / sqlx-cli (with remediation hint) |
| `web-test` | `npm ci && npm test` | `npm test` after a stale-lockfile check | if `web/package-lock.json` is newer than `web/node_modules/.package-lock.json`, FAIL with remediation — closes the false-pass gap where CI's `npm ci` would have caught a stale local install |
| `web-lint` | `npm run check` + `eslint .` + `lint:e2e` + `screen_specs_coverage_test` + `ses_iam_configset_coupling_test` | identical (with the same stale-lockfile check) | none |
| `check-sizes` | `bash scripts/check-sizes.sh` | identical | scans `infra/*/src` and `web/src` for `.rs/.ts/.svelte` hard-limit violations |
| `secret-scan` | `gitleaks detect --redact -v --exit-code=2` | `scripts/reliability/lib/security_checks.sh::check_secret_scan` | uses the repo's reliability secret scan instead of gitleaks; SSOT-aligned with the broader reliability gate |

## SKIP semantics

A SKIP is **not** a silent pass. The script exits 0 only because your local environment couldn't satisfy a prereq (e.g. no `sqlx-cli`, no postgres on `127.0.0.1:5432`) — but the SKIP banner names the missing prereq with the exact remediation command. Compare to a FAIL which means your code broke something.

The script distinguishes between **missing tool** ("install sqlx-cli") and **service unreachable** ("start postgres"), since they need different fixes. Postgres reachability is probed via bash's built-in `/dev/tcp` so the probe itself has no install dependency.

## Current fast/full behavior

As of 2026-07-18, `--fast` and `--full` share the same scheduled parallel gate list from `schedule()` and `SCHEDULED_GATES` in `scripts/local-ci.sh:619-663`. `schedule()` only filters by `SINGLE_GATE`; it does not read `$MODE`. The mode difference is the later `RUN_RUST_TEST_SEQUENTIAL` decision in `scripts/local-ci.sh:675-681`: `--full` adds `rust-test` after the parallel batch, while default `--fast` does not. `--gate rust-test` also runs the Rust test gate through that sequential path.

This means `bash scripts/local-ci.sh --fast` is a cheap pre-push gate for formatting, lint, static contracts, web checks, migration prereqs, secret checks, and the other scheduled fast gates, but it is not currently in the pre-push path for the Rust test suite. A green fast run can coexist with a red `cd infra && cargo test -p api --no-fail-fast` result.

`run_gate()` in `scripts/local-ci.sh:162` records PASS, SKIP, or FAIL results in the per-run results file. The summary table in the final block reads that results file, counts FAIL/SKIP/PASS rows, prints skip reasons, and exits non-zero only when `fail_count > 0`. A scheduled gate must therefore appear in the `=== local-ci summary ===` table with a `PASS` status and non-zero `SECS` before it should be treated as executed coverage.

## Successor lane constraints

The next lane that closes the Rust-test pre-push gap must treat these as binding scoping constraints:

1. **Mode selection does not exist the way it appears to.** `schedule()` (`local-ci.sh:619`) filters on `SINGLE_GATE` only and never reads `$MODE`. `--fast` and `--full` run the **identical** `SCHEDULED_GATES` array; the sole difference is `RUN_RUST_TEST_SEQUENTIAL` (`:675-681`). So "add a gate to `--fast` only" is not expressible without mode-conditional scheduling.
2. **Registration is five separate sites, and missing one yields a gate that cannot fail.** (a) `gate_<name_with_underscores>()` function; (b) `schedule <name-with-dashes>` (`:638-663`); (c) the hardcoded `Known gates:` string (~`:692`); (d) the `case "$gate" in …) run_gate …` dispatch (`:719-744`); (e) optionally the sequential block (`:675-681`, `:762-765`). **Site (d)'s `case` has no `*)` default arm** — miss it and the gate is scheduled, counted in `total_gates`, and **printed in the `Running N gate(s):` banner**, yet executes nothing, records no result, and the script exits 0. Acceptance must therefore assert the gate appears in the `=== local-ci summary ===` table with a `PASS` status and non-zero SECS. Presence in the banner proves nothing.
3. **Cost is ~7x higher than the naive measurement.** The often-quoted "6 seconds" is the platform target's in-process runtime, not `cargo test -p api`. Measured warm (87 GB target dir): 42s with zero source changes; after touching one source file, 55.8s compile+link alone plus ~24s execution ≈ 80s. `cargo clippy -p api --all-targets` (50s) invalidates test artifacts, so a run doing both pays codegen twice. There is no `CARGO_TARGET_DIR` and no `.cargo/config.toml`, so **every batman worktree builds cold** — 505 deps including the AWS SDK — which is minutes, not seconds.
4. **Parallel scheduling reintroduces a documented false-FAIL.** `run_gate` (`:162`) backgrounds each gate. The script's own comment (`:631-637`) records that cargo test "saturates the CPU and starves vitest, which has tight 5s per-test timeouts… produced false-FAIL on web-test that CI wouldn't have seen. (Real bug found 2026-04-30 round-2 self-review.)" A Rust-test gate must take the sequential slot alongside `rust-test`, which means touching the `RUN_*_SEQUENTIAL` framework.
5. **Two ways to ship a green gate that tests nothing.** (i) `scripts/reliability/profiles/` is gitignored (`.gitignore:30`) and absent in fresh worktrees; `gate_rust_test` calls `scripts/reliability/seed-test-profiles.sh` first for exactly this reason, and a gate that skips it is red everywhere. (ii) `run_gate` maps `$SKIP_EXIT_CODE` to `SKIP` and the final block exits 0 when `skip_count > 0` — so an agent can make the gate skip itself to green. Any successor lane must state that its Rust gate MUST NOT return `$SKIP_EXIT_CODE` under any condition.

## Where logs live

Per-gate stdout+stderr is captured during the run. After the script exits, all logs are moved to `${TMPDIR:-/tmp}/local-ci-last-logs/<gate>.log` and persist until the next `local-ci.sh` invocation, which clears the directory and re-populates it. The log paths printed in the summary table point at this persisted location, so they remain readable for as long as you're investigating the run.

## When to use which mode

- **Tight inner loop** while iterating on one crate or one file: use the relevant single-purpose `cargo check -p <crate>` / `npx vitest run path/to/test.ts` etc. (still listed in CLAUDE.md). local-ci is for the gate-level confidence check.
- **Before pushing to `main`**: `bash scripts/local-ci.sh` (fast mode). This catches the cheap deterministic gate failures, but it does not currently run the Rust test suite.
- **Before pushing a non-trivial Rust change**: add `--full` so the workspace tests run too.
- **Investigating why CI failed last cycle**: use `--gate <name>` to reproduce just that gate.

## Maintenance

When the staging `.github/workflows/ci.yml` adds, removes, or changes the `deploy-staging` `needs[]` list, mirror the change in `scripts/local-ci.sh`'s `schedule` block and add/remove the corresponding gate function. Each gate function is a short bash function so the mirror stays cheap to keep in sync. The CI workflow file and the local script live in the same repo and ship together via debbie.
