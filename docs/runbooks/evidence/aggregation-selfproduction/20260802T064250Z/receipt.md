# Aggregation Self-Production Receipt

- Date: `20260802T064250Z`
- Repo SHA: `016e714c9c0f582c70a8a00c4614f1c8697c00bb`
- Behavior owner: `scripts/local_real_pipeline_probe.sh`
- Runbook: `docs/runbooks/local_real_pipeline_probe.md`
- Local proof statement: one manually driven local metering and aggregation run produced the exact `usage_daily` row for that run; the produced row matched the Flapjack `/metrics` `POST-PRE` counters and the real aggregation job reported `rows_affected >= 1`.

## Summary

Positive proof passed:

```text
[local-real-pipeline] PRE  search=1 write=5
[local-real-pipeline] POST search=9 write=11
[local-real-pipeline] delta=POST-PRE search=8 write=6 rows_affected=1
LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified
```

Seeded-row negative proof passed its wrapper by rejecting the uncleared seed:

```text
[local-real-pipeline] negative-seeded expected search=0 write=0 rows_affected=1 cleared=false
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared
```

No-traffic negative proof passed its wrapper by rejecting the absent row:

```text
[local-real-pipeline] negative-nodrive expected search=0 write=0 rows_affected=0 cleared=true
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent
```

Launch-matrix stale-rollup specimen: `rollup_stale` from `docs/runbooks/evidence/ses-coverage-a1/20260722T204849Z_jul16_10am_s1_rerun/staging_dunning_delivery.json`.

## Proof Boundary Quoted

## Proof Boundary

Parked: the production systemd timer firing on a real host is out of scope for this local harness — this proves the job PRODUCES correctly when driven manually.

This procedure does not exercise AWS, CloudWatch, staging, EC2, Stripe, or the
web frontend. It proves local production behavior only through the probe owner
above.

## Not Proven Locally

The following deployed behavior is not proven locally.

The local probe does not prove staging or production timer enablement, timer firing, deployed-host database reachability, AWS, CloudWatch, EC2, Stripe, or frontend behavior. The deployed-host artifact that would prove staging timer enablement/firing/database reachability is a staging host timer receipt containing `systemctl is-enabled fjcloud-aggregation-job.timer`, `systemctl list-timers --all fjcloud-aggregation-job.timer`, `journalctl -u fjcloud-aggregation-job.timer -u fjcloud-aggregation-job.service`, and a staging database freshness query for the aggregation-produced `usage_daily` row after the timer fire.

## Command Evidence

### Positive Proof

Command:

```bash
bash scripts/local_real_pipeline_probe.sh
```

Transcript:

```text
[local-demo] Prepared <repo-root>/.env.local
[local-dev-down] flapjack: no PID file found (not running)
[local-dev-down] api: no PID file found (not running)
[local-dev-down] web: no PID file found (not running)
[local-dev-down] Local dev stack torn down
[local-dev-up] Starting Postgres...
 Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Creating 
 Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Created 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Creating 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Created 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Starting 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Started 
[local-dev-up] Waiting for Postgres to be ready...
[local-dev-up] Postgres is ready
[local-dev-up] Starting seaweedfs...
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Creating 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Created 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Starting 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Started 
[local-dev-up] seaweedfs failed health check after 15s (docker compose Health was not 'healthy') — non-fatal; API will fall back to InMemoryObjectStore
[local-dev-up] Starting mailpit...
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Creating 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Created 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Starting 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Started 
[local-dev-up] mailpit is healthy (http://localhost:58025/api/v1/info)
[local-dev-up] Applying migrations to: postgres://griddle:***@127.0.0.1:55433/fjcloud_dev
NOTICE:  relation "_schema_migrations" already exists, skipping
[local-dev-up] 70 already-applied migrations skipped
[local-dev-up] All migrations applied (0 new, 70 skipped)
[local-dev-up] Flapjack binary: <flapjack-dev>/engine/target/debug/flapjack
[local-dev-up] Flapjack provenance: source-receipt:<repo-root>/.local/flapjack-source-receipts/bdb3d9f18040f5d39a0849189832c8215f11629838068d976411310b3393c74b.receipt
[local-dev-up] Starting flapjack (us-east-1) on port 57700...
[local-dev-up] flapjack-us-east-1 is healthy (http://127.0.0.1:57700/health)
[local-dev-up] Starting flapjack (eu-west-1) on port 57701...
[local-dev-up] flapjack-eu-west-1 is healthy (http://127.0.0.1:57701/health)
[local-dev-up] Starting flapjack (eu-central-1) on port 57702...
[local-dev-up] flapjack-eu-central-1 is healthy (http://127.0.0.1:57702/health)
[local-dev-up] 
[local-dev-up] Local dev infrastructure is up!
[local-dev-up]   Postgres:       127.0.0.1:55433 (via Docker Compose)
[local-dev-up]   Flapjack us-east-1: http://localhost:57700
[local-dev-up]   Flapjack eu-west-1: http://localhost:57701
[local-dev-up]   Flapjack eu-central-1: http://localhost:57702
[local-dev-up]   Mailpit UI:     http://localhost:58025
[local-dev-up]   Admin key:      (explicit override set)
[local-dev-up]   Database:       postgres://griddle:***@127.0.0.1:55433/fjcloud_dev
[local-dev-up] 
[local-dev-up] Start the API:
[local-dev-up]   scripts/api-dev.sh
[local-dev-up] 
[local-dev-up] Start the web frontend:
[local-dev-up]   scripts/web-dev.sh
[local-dev-up] 
[local-dev-up] After seeding (scripts/seed_local.sh), start metering:
[local-dev-up]   scripts/start-metering.sh          # single-region
[local-dev-up]   scripts/start-metering.sh --multi-region  # multi-region
[seed] API is healthy at http://127.0.0.1:3001
INSERT 0 3
UPDATE 0
[seed] Verified VM inventory hostnames for 3 default regions
[seed] Flapjack reachable at http://127.0.0.1:57700 — seeding indexes and sample documents
[seed] User already exists: dev@example.com (logging in)
[seed] Verified user email: dev@example.com
[seed] Customer ID for dev@example.com: f651f800-4a52-4b57-9ab3-0a8e7231ec1f
[seed] Set billing plan to shared for dev@example.com
[seed] Verified seeded account for dev@example.com (plan: shared)
[seed] Stripe-synced dev@example.com: cus_local_a845f705837f4e7292a8019fc514b46d
[seed] User already exists: free@example.com (logging in)
[seed] Verified user email: free@example.com
[seed] Customer ID for free@example.com: d2d9cf60-2263-4c6c-916f-63a88e0c0435
[seed] Verified seeded account for free@example.com (plan: free)
[seed] Stripe-synced free@example.com: cus_local_9911a19e9aa743e1a98cba65ee6a5a4c
INSERT 0 93
[seed] Seeded current UTC month usage_daily rows for dev@example.com across 3 regions
[seed] Created index test-index (us-east-1) for dev@example.com
[seed] Created index test-index-eu (eu-west-1) for dev@example.com
[seed] Created index test-index-eu2 (eu-central-1) for dev@example.com
[seed] Created index free-test-index (us-east-1) for free@example.com
[seed] Verified search result doc-1 in test-index
[seed] Seeded 5 sample documents into test-index for dev@example.com
[seed] Verified search result doc-1 in test-index-eu
[seed] Seeded 5 sample documents into test-index-eu for dev@example.com
[seed] Verified search result doc-1 in test-index-eu2
[seed] Seeded 5 sample documents into test-index-eu2 for dev@example.com
[seed] Verified search result doc-1 in free-test-index
[seed] Seeded 5 sample documents into free-test-index for free@example.com
[seed] Verified seeded index names for dev@example.com
[seed] Verified seeded index names for free@example.com
[seed] Verified /billing/estimate for dev@example.com (2026-08)
[seed] Replica already exists: test-index -> eu-west-1
[seed] Replica already exists: test-index-eu -> us-east-1
[seed] Replica already exists: test-index-eu2 -> us-east-1
UPDATE 0
UPDATE 3
[seed] Marked seed replicas as active (0 new)
[seed] 
[seed] Local dev environment seeded successfully!
[seed]   API:      http://127.0.0.1:3001
[seed]   Shared:   dev@example.com
[seed]   Free:     free@example.com
[seed]   Indexes:  4 targets
[start-metering] Found shared customer: f651f800-4a52-4b57-9ab3-0a8e7231ec1f
[start-metering] Starting metering agent for us-east-1 (flapjack=http://127.0.0.1:57700, health=:9091)...
[start-metering] Metering agent started for us-east-1 (PID 59045)
[start-metering]   Log: <repo-root>/.local/metering-agent-us-east-1.log
[start-metering]   Health: http://127.0.0.1:9091/health
[local-real-pipeline] Stopping metering-agent-us-east-1 (PID 59045)...
[local-real-pipeline] PRE  search=1 write=5
[local-real-pipeline] POST search=9 write=11
[local-real-pipeline] delta=POST-PRE search=8 write=6 rows_affected=1
LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified
[local-real-pipeline] Tearing down local stack
[local-dev-down] flapjack: no PID file found (not running)
[local-dev-down] Stopping flapjack-eu-central-1 (PID 25039)...
[local-dev-down] Stopping flapjack-eu-west-1 (PID 21965)...
[local-dev-down] Stopping flapjack-us-east-1 (PID 18689)...
[local-dev-down] Stopping api (PID 27910)...
[local-dev-down] web: no PID file found (not running)
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Removed 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Removed 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Removed 
[local-dev-down]  Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Removing 
[local-dev-down]  Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Removed 
[local-dev-down] Local dev stack torn down
```

### Seeded-Row Negative Proof

Command:

```bash
(
  output_file="$(mktemp "${TMPDIR:-/tmp}/local_real_pipeline_negative_seeded.XXXXXX")"
  trap 'test ! -e "$output_file" || unlink "$output_file"' EXIT
  set +e
  bash scripts/local_real_pipeline_probe.sh --negative-seeded >"$output_file" 2>&1
  probe_rc=$?
  set -e
  cat "$output_file"
  test "$probe_rc" -ne 0
  grep -Fx 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared' "$output_file"
)
```

Transcript:

```text
[local-demo] Prepared <repo-root>/.env.local
[local-dev-down] flapjack: no PID file found (not running)
[local-dev-down] api: no PID file found (not running)
[local-dev-down] web: no PID file found (not running)
[local-dev-down] Local dev stack torn down
[local-dev-up] Starting Postgres...
 Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Creating 
 Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Created 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Creating 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Created 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Starting 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Started 
[local-dev-up] Waiting for Postgres to be ready...
[local-dev-up] Postgres is ready
[local-dev-up] Starting seaweedfs...
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Creating 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Created 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Starting 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Started 
[local-dev-up] seaweedfs failed health check after 15s (docker compose Health was not 'healthy') — non-fatal; API will fall back to InMemoryObjectStore
[local-dev-up] Starting mailpit...
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Creating 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Created 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Starting 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Started 
[local-dev-up] mailpit is healthy (http://localhost:58025/api/v1/info)
[local-dev-up] Applying migrations to: postgres://griddle:***@127.0.0.1:55433/fjcloud_dev
NOTICE:  relation "_schema_migrations" already exists, skipping
[local-dev-up] 70 already-applied migrations skipped
[local-dev-up] All migrations applied (0 new, 70 skipped)
[local-dev-up] Flapjack binary: <flapjack-dev>/engine/target/debug/flapjack
[local-dev-up] Flapjack provenance: source-receipt:<repo-root>/.local/flapjack-source-receipts/bdb3d9f18040f5d39a0849189832c8215f11629838068d976411310b3393c74b.receipt
[local-dev-up] Starting flapjack (us-east-1) on port 57700...
[local-dev-up] flapjack-us-east-1 is healthy (http://127.0.0.1:57700/health)
[local-dev-up] Starting flapjack (eu-west-1) on port 57701...
[local-dev-up] flapjack-eu-west-1 is healthy (http://127.0.0.1:57701/health)
[local-dev-up] Starting flapjack (eu-central-1) on port 57702...
[local-dev-up] flapjack-eu-central-1 is healthy (http://127.0.0.1:57702/health)
[local-dev-up] 
[local-dev-up] Local dev infrastructure is up!
[local-dev-up]   Postgres:       127.0.0.1:55433 (via Docker Compose)
[local-dev-up]   Flapjack us-east-1: http://localhost:57700
[local-dev-up]   Flapjack eu-west-1: http://localhost:57701
[local-dev-up]   Flapjack eu-central-1: http://localhost:57702
[local-dev-up]   Mailpit UI:     http://localhost:58025
[local-dev-up]   Admin key:      (explicit override set)
[local-dev-up]   Database:       postgres://griddle:***@127.0.0.1:55433/fjcloud_dev
[local-dev-up] 
[local-dev-up] Start the API:
[local-dev-up]   scripts/api-dev.sh
[local-dev-up] 
[local-dev-up] Start the web frontend:
[local-dev-up]   scripts/web-dev.sh
[local-dev-up] 
[local-dev-up] After seeding (scripts/seed_local.sh), start metering:
[local-dev-up]   scripts/start-metering.sh          # single-region
[local-dev-up]   scripts/start-metering.sh --multi-region  # multi-region
[seed] API is healthy at http://127.0.0.1:3001
INSERT 0 3
UPDATE 0
[seed] Verified VM inventory hostnames for 3 default regions
[seed] Flapjack reachable at http://127.0.0.1:57700 — seeding indexes and sample documents
[seed] User already exists: dev@example.com (logging in)
[seed] Verified user email: dev@example.com
[seed] Customer ID for dev@example.com: f651f800-4a52-4b57-9ab3-0a8e7231ec1f
[seed] Set billing plan to shared for dev@example.com
[seed] Verified seeded account for dev@example.com (plan: shared)
[seed] Stripe-synced dev@example.com: cus_local_a845f705837f4e7292a8019fc514b46d
[seed] User already exists: free@example.com (logging in)
[seed] Verified user email: free@example.com
[seed] Customer ID for free@example.com: d2d9cf60-2263-4c6c-916f-63a88e0c0435
[seed] Verified seeded account for free@example.com (plan: free)
[seed] Stripe-synced free@example.com: cus_local_9911a19e9aa743e1a98cba65ee6a5a4c
INSERT 0 93
[seed] Seeded current UTC month usage_daily rows for dev@example.com across 3 regions
[seed] Created index test-index (us-east-1) for dev@example.com
[seed] Created index test-index-eu (eu-west-1) for dev@example.com
[seed] Created index test-index-eu2 (eu-central-1) for dev@example.com
[seed] Created index free-test-index (us-east-1) for free@example.com
[seed] Verified search result doc-1 in test-index
[seed] Seeded 5 sample documents into test-index for dev@example.com
[seed] Verified search result doc-1 in test-index-eu
[seed] Seeded 5 sample documents into test-index-eu for dev@example.com
[seed] Verified search result doc-1 in test-index-eu2
[seed] Seeded 5 sample documents into test-index-eu2 for dev@example.com
[seed] Verified search result doc-1 in free-test-index
[seed] Seeded 5 sample documents into free-test-index for free@example.com
[seed] Verified seeded index names for dev@example.com
[seed] Verified seeded index names for free@example.com
[seed] Verified /billing/estimate for dev@example.com (2026-08)
[seed] Replica already exists: test-index -> eu-west-1
[seed] Replica already exists: test-index-eu -> us-east-1
[seed] Replica already exists: test-index-eu2 -> us-east-1
UPDATE 0
UPDATE 3
[seed] Marked seed replicas as active (0 new)
[seed] 
[seed] Local dev environment seeded successfully!
[seed]   API:      http://127.0.0.1:3001
[seed]   Shared:   dev@example.com
[seed]   Free:     free@example.com
[seed]   Indexes:  4 targets
[local-real-pipeline] negative-seeded expected search=0 write=0 rows_affected=1 cleared=false
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared
[local-real-pipeline] Tearing down local stack
[local-dev-down] flapjack: no PID file found (not running)
[local-dev-down] Stopping flapjack-eu-central-1 (PID 35609)...
[local-dev-down] Stopping flapjack-eu-west-1 (PID 33695)...
[local-dev-down] Stopping flapjack-us-east-1 (PID 31509)...
[local-dev-down] Stopping api (PID 37348)...
[local-dev-down] web: no PID file found (not running)
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Removed 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Removed 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Removed 
[local-dev-down]  Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Removing 
[local-dev-down]  Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Removed 
[local-dev-down] Local dev stack torn down
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared
```

### No-Traffic Negative Proof

Command:

```bash
(
  output_file="$(mktemp "${TMPDIR:-/tmp}/local_real_pipeline_negative_nodrive.XXXXXX")"
  trap 'test ! -e "$output_file" || unlink "$output_file"' EXIT
  set +e
  bash scripts/local_real_pipeline_probe.sh --negative-nodrive >"$output_file" 2>&1
  probe_rc=$?
  set -e
  cat "$output_file"
  test "$probe_rc" -ne 0
  grep -Fx 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent' "$output_file"
)
```

Transcript:

```text
[local-demo] Prepared <repo-root>/.env.local
[local-dev-down] flapjack: no PID file found (not running)
[local-dev-down] api: no PID file found (not running)
[local-dev-down] web: no PID file found (not running)
[local-dev-down] Local dev stack torn down
[local-dev-up] Starting Postgres...
 Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Creating 
 Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Created 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Creating 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Created 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Starting 
 Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Started 
[local-dev-up] Waiting for Postgres to be ready...
[local-dev-up] Postgres is ready
[local-dev-up] Starting seaweedfs...
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Creating 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Created 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Starting 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Started 
[local-dev-up] seaweedfs failed health check after 15s (docker compose Health was not 'healthy') — non-fatal; API will fall back to InMemoryObjectStore
[local-dev-up] Starting mailpit...
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Creating 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Created 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Starting 
[local-dev-up]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Started 
[local-dev-up] mailpit is healthy (http://localhost:58025/api/v1/info)
[local-dev-up] Applying migrations to: postgres://griddle:***@127.0.0.1:55433/fjcloud_dev
NOTICE:  relation "_schema_migrations" already exists, skipping
[local-dev-up] 70 already-applied migrations skipped
[local-dev-up] All migrations applied (0 new, 70 skipped)
[local-dev-up] Flapjack binary: <flapjack-dev>/engine/target/debug/flapjack
[local-dev-up] Flapjack provenance: source-receipt:<repo-root>/.local/flapjack-source-receipts/bdb3d9f18040f5d39a0849189832c8215f11629838068d976411310b3393c74b.receipt
[local-dev-up] Starting flapjack (us-east-1) on port 57700...
[local-dev-up] flapjack-us-east-1 is healthy (http://127.0.0.1:57700/health)
[local-dev-up] Starting flapjack (eu-west-1) on port 57701...
[local-dev-up] flapjack-eu-west-1 is healthy (http://127.0.0.1:57701/health)
[local-dev-up] Starting flapjack (eu-central-1) on port 57702...
[local-dev-up] flapjack-eu-central-1 is healthy (http://127.0.0.1:57702/health)
[local-dev-up] 
[local-dev-up] Local dev infrastructure is up!
[local-dev-up]   Postgres:       127.0.0.1:55433 (via Docker Compose)
[local-dev-up]   Flapjack us-east-1: http://localhost:57700
[local-dev-up]   Flapjack eu-west-1: http://localhost:57701
[local-dev-up]   Flapjack eu-central-1: http://localhost:57702
[local-dev-up]   Mailpit UI:     http://localhost:58025
[local-dev-up]   Admin key:      (explicit override set)
[local-dev-up]   Database:       postgres://griddle:***@127.0.0.1:55433/fjcloud_dev
[local-dev-up] 
[local-dev-up] Start the API:
[local-dev-up]   scripts/api-dev.sh
[local-dev-up] 
[local-dev-up] Start the web frontend:
[local-dev-up]   scripts/web-dev.sh
[local-dev-up] 
[local-dev-up] After seeding (scripts/seed_local.sh), start metering:
[local-dev-up]   scripts/start-metering.sh          # single-region
[local-dev-up]   scripts/start-metering.sh --multi-region  # multi-region
[seed] API is healthy at http://127.0.0.1:3001
INSERT 0 3
UPDATE 0
[seed] Verified VM inventory hostnames for 3 default regions
[seed] Flapjack reachable at http://127.0.0.1:57700 — seeding indexes and sample documents
[seed] User already exists: dev@example.com (logging in)
[seed] Verified user email: dev@example.com
[seed] Customer ID for dev@example.com: f651f800-4a52-4b57-9ab3-0a8e7231ec1f
[seed] Set billing plan to shared for dev@example.com
[seed] Verified seeded account for dev@example.com (plan: shared)
[seed] Stripe-synced dev@example.com: cus_local_a845f705837f4e7292a8019fc514b46d
[seed] User already exists: free@example.com (logging in)
[seed] Verified user email: free@example.com
[seed] Customer ID for free@example.com: d2d9cf60-2263-4c6c-916f-63a88e0c0435
[seed] Verified seeded account for free@example.com (plan: free)
[seed] Stripe-synced free@example.com: cus_local_9911a19e9aa743e1a98cba65ee6a5a4c
INSERT 0 93
[seed] Seeded current UTC month usage_daily rows for dev@example.com across 3 regions
[seed] Created index test-index (us-east-1) for dev@example.com
[seed] Created index test-index-eu (eu-west-1) for dev@example.com
[seed] Created index test-index-eu2 (eu-central-1) for dev@example.com
[seed] Created index free-test-index (us-east-1) for free@example.com
[seed] Verified search result doc-1 in test-index
[seed] Seeded 5 sample documents into test-index for dev@example.com
[seed] Verified search result doc-1 in test-index-eu
[seed] Seeded 5 sample documents into test-index-eu for dev@example.com
[seed] Verified search result doc-1 in test-index-eu2
[seed] Seeded 5 sample documents into test-index-eu2 for dev@example.com
[seed] Verified search result doc-1 in free-test-index
[seed] Seeded 5 sample documents into free-test-index for free@example.com
[seed] Verified seeded index names for dev@example.com
[seed] Verified seeded index names for free@example.com
[seed] Verified /billing/estimate for dev@example.com (2026-08)
[seed] Replica already exists: test-index -> eu-west-1
[seed] Replica already exists: test-index-eu -> us-east-1
[seed] Replica already exists: test-index-eu2 -> us-east-1
UPDATE 0
UPDATE 3
[seed] Marked seed replicas as active (0 new)
[seed] 
[seed] Local dev environment seeded successfully!
[seed]   API:      http://127.0.0.1:3001
[seed]   Shared:   dev@example.com
[seed]   Free:     free@example.com
[seed]   Indexes:  4 targets
[local-real-pipeline] negative-nodrive expected search=0 write=0 rows_affected=0 cleared=true
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent
[local-real-pipeline] Tearing down local stack
[local-dev-down] flapjack: no PID file found (not running)
[local-dev-down] Stopping flapjack-eu-central-1 (PID 68450)...
[local-dev-down] Stopping flapjack-eu-west-1 (PID 66212)...
[local-dev-down] Stopping flapjack-us-east-1 (PID 63893)...
[local-dev-down] Stopping api (PID 70740)...
[local-dev-down] web: no PID file found (not running)
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Stopping 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-postgres-1 Removed 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-mailpit-1 Removed 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Stopped 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Removing 
[local-dev-down]  Container fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev-seaweedfs-1 Removed 
[local-dev-down]  Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Removing 
[local-dev-down]  Network fjcloud_aug02_5am_4_aggregation_job_local_selfproduction_fjcloud_dev_default Removed 
[local-dev-down] Local dev stack torn down
LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent
```
