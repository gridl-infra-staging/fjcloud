# Reliability Profiling Harness

Captures CPU, memory, disk, and query-latency envelopes for 1K, 10K, and 100K document profiles against a local integration stack.

## Prerequisites

- Integration stack running: `scripts/integration-up.sh`
- `python3` available on PATH
- `curl` available on PATH

## Usage

### Run all tiers

```bash
RELIABILITY=1 scripts/reliability/capture-all.sh
```

### Run a single tier

```bash
RELIABILITY=1 scripts/reliability/run-profile.sh 10k
```

### Seed documents only

```bash
RELIABILITY=1 scripts/reliability/seed-documents.sh 1k
```

## Output

Profile artifacts are written to `scripts/reliability/profiles/`:

| File                  | Contents                                        |
|-----------------------|-------------------------------------------------|
| `{tier}_cpu.json`     | CPU utilisation at idle, seeding, query-load     |
| `{tier}_mem.json`     | RSS at idle, post-seed, under query-load         |
| `{tier}_disk.json`    | Disk bytes after seeding                         |
| `{tier}_latency.json` | Query latency p50/p95/p99 under steady load      |
| `summary.json`        | Combined envelope data for all tiers             |

Each artifact is a JSON object with keys: `tier`, `timestamp`, `metric`, `envelope`.

## Validation

Run the profile artifact tests to verify presence, freshness, and schema:

```bash
bash scripts/tests/reliability_profile_test.sh
```

## Configuration

| Variable                      | Default | Description                              |
|-------------------------------|---------|------------------------------------------|
| `RELIABILITY`                 | `0`     | Set to `1` to enable profiling           |
| `API_PORT`                    | `3099`  | API server port                          |
| `FLAPJACK_PORT`               | `7799`  | Flapjack engine port                     |
| `RELIABILITY_QUERY_ITERATIONS` | `200`  | Number of queries per latency capture    |
| `RELIABILITY_STALENESS_DAYS`  | `30`    | Max artifact age before test failure     |

## Downstream Consumers

- **Scheduler fixtures** (`infra/api/tests/common/capacity_profiles.rs`): Consumes measured envelope values for `PROFILE_1K`, `PROFILE_10K`, `PROFILE_100K` constants.
- **Stage 2+**: Overload/migration tests reference these baselines for threshold calibration.
- **Stage 5**: Backend reliability gate runs `reliability_profile_test.sh` as part of the aggregate verdict.
