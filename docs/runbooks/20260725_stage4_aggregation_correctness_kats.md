# Aggregation Correctness KATs

## Purpose

Use this guide to run the aggregation-correctness known-answer tests built for
the local live pipeline and DB-backed billing aggregation boundary. It is the
operator guide only; behavior stays owned by:

- `docs/runbooks/local_real_pipeline_probe.md`
- `scripts/aggregation_correctness_kat.sh`
- `infra/api/tests/integration/aggregation_known_answer_test.rs`
- `infra/api/tests/billing.rs`

Run every command from the repository root unless the command itself changes
directory. All checks are unattended CLI commands.

## Prerequisites

- Use the repository root that contains `.env.local`, `docker-compose.yml`,
  `scripts/`, and `infra/`.
- For the live-pipeline KAT, let `scripts/aggregation_correctness_kat.sh`
  own stack startup and teardown through W2's `scripts/lib/local_real_pipeline_run.sh`.
  Do not stop unrelated shared-host processes; the probe-owned teardown trap
  handles only processes started by that run.
- For the DB-backed KAT, `.env.local` must provide a real local PostgreSQL
  `DATABASE_URL`. A missing database, compile-only result, or skip path is not
  closure evidence.

No new environment variable is introduced by these KATs. `LRP_DRIVE_WRITES`,
`LRP_DRIVE_SEARCHES`, and the real-pipeline timeout knobs remain documented in
`docs/env-vars.md`.

## Stage 2 Live-Pipeline KAT

Run:

```bash
bash scripts/aggregation_correctness_kat.sh
```

This command drives the full local metering to aggregation pipeline. The wrapper
pins `LRP_DRIVE_WRITES=11` and `LRP_DRIVE_SEARCHES=5`. W2's traffic-key write
adds one write operation, so the accepted write oracle is `1 + 11 = 12`; the
accepted search oracle is `5`.

PASS requires exit code 0 and both status lines:

```text
LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified
AGGREGATION_CORRECTNESS_KAT: PASS pipeline_executed=true ... daily_write_operations=12 daily_search_requests=5 raw_write_sum=12 raw_search_sum=5
```

The non-vacuous denominators are:

- `pipeline_executed=true`
- `daily_write_operations=12`
- `daily_search_requests=5`
- `raw_write_sum=12`
- `raw_search_sum=5`

The `25000/250000` pair is the rejected seed discriminator from
`scripts/seed_local.sh`, not an accepted fixture. Any KAT output that accepts
those seed values fails the proof.

## Stage 3 DB-Backed KAT

Run:

```bash
DATABASE_URL="$(
  python3 - <<'PY'
from pathlib import Path

for raw_line in Path(".env.local").read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or not line.startswith("DATABASE_URL="):
        continue
    value = line.split("=", 1)[1]
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    print(value)
    break
else:
    raise SystemExit("DATABASE_URL missing from .env.local")
PY
)" && cd infra && DATABASE_URL="$DATABASE_URL" cargo test -p api --test billing aggregation_known_answer -- --nocapture
```

PASS requires a real `DATABASE_URL`, three executed tests, `3 passed`, and no
`SKIP` or missing-database path. The printed observations must include:

- gauge storage: `4_000_000`
- half-tie document average: `1_500_001`
- UTC boundary writes: target `30`, next day `40`
- month values: Jan `2`, leap-Feb `1`, Apr `3`, Feb `1`, sparse-Feb `1`
- 31-day write total: `3_100`

## Proof Boundary

Stage 2 proves the full live local path: metering agent records, aggregation
rollup, W2 evidence classification, and the wrapper's exact daily/raw counter
oracle.

Stage 3 injects only agent-shaped `usage_records` because 28, 29, 30, and 31
real calendar days cannot fit a test run. It then executes the production
`ROLLUP_SQL` and `summarize`; neither rollup nor summarize is substituted.

Do not use `scripts/seed_local.sh`'s direct `usage_daily` insert as proof for
these KATs. Park only real-calendar multi-month agent runs and the production
systemd timer as outside this local proof boundary.

## Fast-Gate Contract Check

The routine fast gate owns the fail-capable string-level contract check:

```bash
bash scripts/local-ci.sh --gate local-real-pipeline-contract
```

The persisted log at
`${TMPDIR:-/tmp}/local-ci-last-logs/local-real-pipeline-contract.log` must show
that `scripts/tests/aggregation_kat_probe_contract_test.sh` ran, including PASS
assertions for `good_probe_bundle` and drifted fixture rejection.
