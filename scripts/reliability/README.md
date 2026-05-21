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

### Reconcile VM inventory vs managed EC2

```bash
bash scripts/reliability/validate_vm_inventory_ec2_consistency.sh \
  --evidence-dir docs/runbooks/evidence/fleet-recovery/$(date -u +%Y%m%dT%H%M%SZ)_inventory_probe
```

The probe emits a JSON summary to stdout and writes raw capture files when
`--evidence-dir` is provided:

- `inventory_rows.json` (active AWS `vm_inventory` rows)
- `deployment_rows.json` (`status='provisioning'` rows limited to AWS or `provisioning-lock:*`, plus non-provisioning AWS provider-qualified `customer_deployments` linkage rows)
- `ec2_instances.json` (non-terminated `managed-by=fjcloud` EC2 rows; the shared-fleet drift bucket only evaluates `vm-shared-*` hosts)

Summary buckets:

- `inventory_rows_without_nonterminated_ec2_match`
- `managed_instances_without_inventory_match` (shared `vm-shared-*` managed EC2 only)
- `deployment_linkage_mismatches`
- `stuck_shared_provisioning_rows`

Exit codes:

- `0`: all buckets are zero
- `1`: one or more reconciliation buckets are nonzero
- `2`: usage/system error

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
