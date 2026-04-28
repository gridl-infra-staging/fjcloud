# Incident Response

## Severity definitions

| Level | Definition | Examples | Response time |
|-------|-----------|----------|---------------|
| P1 — Critical | Service is down or major feature completely broken | API unreachable, all VMs unhealthy, billing charging wrong amounts | Immediate |
| P2 — Major | Degraded performance or partial feature failure | Elevated latency, some VMs unhealthy, webhook processing delayed | Within 1 hour |
| P3 — Minor | Cosmetic or low-impact issue | Admin panel UI glitch, non-critical log errors, single customer affected | Within 1 business day |

## Incident workflow

### 1. Detection
- AlertService fires Critical/Warning alerts via Slack/Discord
- Customer reports via support
- Monitoring dashboards show anomalies

### 2. Triage
- Assess severity (P1/P2/P3)
- Identify affected scope (all customers, single customer, single region)
- Assign incident owner

### 3. Communication (customer-comms first)

For customer-visible P1/P2 incidents, publish status immediately before deep investigation:

```bash
# Staging example
bash scripts/set_status.sh staging degraded "Investigating elevated API errors"

# Prod example
bash scripts/set_status.sh prod outage "Service disruption under investigation"
```

- `bash scripts/set_status.sh <env> <status> [message]` writes `service_status.json` to `s3://fjcloud-releases-<env>/service_status.json`.
- The command verifies the public object URL `https://fjcloud-releases-<env>.s3.amazonaws.com/service_status.json` before returning.
- No deploy or process restart is required.
- Omitting `[message]` clears the public incident text (the published payload omits `message`):
  - `bash scripts/set_status.sh prod operational`
  - `bash scripts/set_status.sh staging operational`
- Post in #incidents Slack channel.
- For P1: notify all stakeholders immediately.

#### One-time operator setup for status publishing (repeat for staging and prod)

Run these prerequisites once per releases bucket (`fjcloud-releases-staging` and `fjcloud-releases-prod`) before first use:

1. Keep ACL blocking enabled, but allow policy-based public read for one object only.
   - Keep `BlockPublicAcls=true` and `IgnorePublicAcls=true`.
   - Set `BlockPublicPolicy=false` and `RestrictPublicBuckets=false`.
2. Attach a bucket policy that grants `s3:GetObject` on exactly `arn:aws:s3:::fjcloud-releases-<env>/service_status.json` (no wildcard release-artifact prefixes).
3. Configure bucket CORS for `GET` only from the matching site origin:
   - Staging bucket origin: `https://staging.cloud.flapjack.foo`
   - Prod bucket origin: `https://cloud.flapjack.foo`
4. Seed the initial object before first incident command:
   - `bash scripts/set_status.sh staging operational`
   - `bash scripts/set_status.sh prod operational`

Secret/env loading precedence is owned by [`docs/design/secret_sources.md`](../design/secret_sources.md) and enforced by `scripts/lib/env.sh::load_env_file`; do not duplicate loader rules in incident steps.

### 4. Investigation & resolution
- Follow relevant runbook (VM health, customer suspension, invoice troubleshooting, etc.)
- For credential/signing-key incidents, use [`docs/runbooks/secret_rotation.md`](secret_rotation.md).
- Document actions taken in the incident Slack thread
- Apply fix and verify resolution

### 5. Recovery
- Clear customer-facing incident status as soon as mitigation is confirmed:
  - `bash scripts/set_status.sh prod operational`
  - `bash scripts/set_status.sh staging operational`
  - Omitting `[message]` clears the public incident text.
- Verify all affected customers are restored
- Monitor for recurrence (30 minutes minimum)

### 6. Post-incident review
- Conduct within 48 hours of resolution
- Use the template below

## Post-incident review template

```markdown
# Post-Incident Review — [Date] — [Brief Title]

## Summary
What happened, when, and who was affected.

## Timeline
- HH:MM — Detection: how was it discovered
- HH:MM — Response: first action taken
- HH:MM — Mitigation: temporary fix applied
- HH:MM — Resolution: root cause fixed
- HH:MM — Monitoring: confirmed stable

## Root cause
What caused the incident.

## Impact
- Duration: X hours Y minutes
- Customers affected: N
- Revenue impact: $X (if applicable)

## Action items
- [ ] Fix to prevent recurrence
- [ ] Monitoring improvement
- [ ] Runbook update
```

## Escalation path

1. On-call engineer (primary responder)
2. Engineering lead
3. CTO

## Stage 5 Coverage: Reliability Gate Failure Runbooks

### Flapjack crash

- **Failure mode**: Flapjack task crashes during replication or lag-monitoring cycles.
- **Detection**:
  - `reliability_replication_tests` fails in Stage 5 gate output.
- **Expected alert**: Check result `reliability_replication_tests` status `fail` and `reason` includes failure context.
- **Triage**:
  1. Inspect Flapjack task status and recent crash logs.
  2. Verify DB connectivity and API credentials used by replication code paths.
  3. Confirm source/replica endpoints are reachable.
- **Resolution**:
  1. Restart/redeploy Flapjack.
  2. Validate replication paths for the affected replicas via health checks.
  3. Re-run Stage 5 gate and confirm replication checks pass.

### Replication failure

- **Failure mode**: Replication API calls fail while syncing source/replica pairs.
- **Detection**:
  - `reliability_replication_tests` fails.
  - Replication lag or replica sync dashboards show stale state.
- **Expected alert**: Stage 5 reports `reliability_replication_tests` failure.
- **Triage**:
  1. Identify affected source/replica pair and failed HTTP call path.
  2. Verify network reachability and service health of both endpoints.
  3. Check authentication/authorization for replication endpoints.
- **Resolution**:
  1. Remediate transient infra issues (DNS, ACLs, network policies).
  2. Retry replication path after recovery.
  3. Escalate if backlog remains and replica remains stale.

### Scheduler overload

- **Failure mode**: Node index overload causes migration scheduling failures or stuck `request_migration` loops.
- **Detection**:
  - `reliability_scheduler_tests` fails.
  - Overload alarms and scheduler latency counters increase.
- **Expected alert**: Stage 5 reports `reliability_scheduler_tests` failure.
- **Triage**:
  1. Check scheduler logs for repeated migration attempt patterns.
  2. Confirm overload duration and in-flight migration state.
  3. Verify infra capacity limits for affected index shard.
- **Resolution**:
  1. Temporarily reduce overload pressure and resume scheduling.
  2. Clear stale in-flight migration state only if safe.
  3. Re-run Stage 5 scheduler suite before normalizing traffic.

### DB disconnect

- **Failure mode**: Metering writes fail after DB disconnect/reconnect cycles; API provisioning leaves partial state after repo failures.
- **Detection**:
  - `reliability_metering_tests` fails — metering-agent circuit breaker, write failure, or idempotency key tests detect DB disconnect regressions.
  - `reliability_api_crash_tests` fails — provisioning rollback leaves partial state (orphaned customer_tenant rows, SSM secrets without VMs).
  - Circuit-breaker or DB error-rate alerts fire.
- **Expected alert**: Stage 5 reports `reliability_metering_tests` or `reliability_api_crash_tests` failure.
- **Triage**:
  1. Confirm DB availability and connection pool health.
  2. Inspect metering write errors and retry/backoff state.
  3. Verify no partial writes were committed for failed operations.
- **Resolution**:
  1. Restore DB and wait for breaker cooldown.
  2. Re-run affected API paths and ensure idempotent recovery behavior.
  3. Keep monitoring for repeated disconnect spikes.

### Auth revocation

- **Failure mode**: Secret-manager/object-store auth tokens are revoked or denied (403-like paths).
- **Detection**:
  - `reliability_cold_tier_tests` fails.
  - Retry counters hit max for snapshot retries in cold-tier path.
- **Expected alert**: Stage 5 reports `reliability_cold_tier_tests` failure with alert/critical reason.
- **Triage**:
  1. Validate IAM role, secret-store credentials, and object-store permissions.
  2. Check for recent key rotations and token expiry windows.
  3. Confirm affected snapshots can be recreated with healthy permissions.
- **Resolution**:
  1. Reissue credentials or rotate keys.
  2. Re-run cold-tier flow and confirm critical alert clears.

### Security scan failure

- **Failure mode**: Repo security checks detect seeded/real insecure patterns or dependency risk.
- **Detection**:
  - `security_secret_scan`, `security_dep_audit`, `security_sql_guard`, or `security_sql_guard_tests` fail.
- **Expected alert**: Stage 5 output includes `fail` status with one of:
  - `SECURITY_SECRET_FOUND`
  - `SECURITY_DEP_AUDIT_FAIL` / `SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING`
  - `SECURITY_SQL_UNSAFE`
- **Triage**:
  1. Inspect failure `reason` and `details` payload for exact artifact paths.
  2. Confirm whether findings are genuine or false-positive.
  3. Coordinate remediation in code/security ownership area.
- **Resolution**:
  1. Fix insecure code/dependency before merge.
  2. Re-run Stage 5 until all security checks return pass.

### Profile freshness failure

- **Failure mode**: Capacity profile artifacts are missing or stale (older than 30 days), causing `reliability_profile_tests` to fail with `PROFILE_MISSING` or `PROFILE_STALE` reason codes.
- **Detection**:
  - Gate output shows `reliability_profile_tests` status `fail`.
  - Reason code includes `PROFILE_MISSING` (artifact file absent) or `PROFILE_STALE` (artifact timestamp exceeds staleness threshold).
- **Triage**:
  1. Check artifact timestamps in `scripts/reliability/profiles/` — confirm which tier/metric artifacts are missing or outdated.
  2. Verify that `scripts/reliability/seed-test-profiles.sh` has been run recently (within the last 30 days).
  3. Check `RELIABILITY_STALENESS_DAYS` env var if a non-default threshold applies.
- **Resolution**:
  1. Re-run `bash scripts/reliability/seed-test-profiles.sh` to regenerate all 13 profile artifacts from current Rust constants.
  2. Alternatively, run a real capacity capture and copy results into `scripts/reliability/profiles/`.
  3. Re-run the gate and confirm `reliability_profile_tests` returns `RELIABILITY_PROFILE_TESTS_PASS`.

### Replication auth revocation

- **Failure mode**: Replication API authentication fails repeatedly. After 5 consecutive HTTP 401 responses (`MAX_CONSECUTIVE_AUTH_FAILURES = 5`), `ReplicationOrchestrator` marks the replica `failed` with `ReplicationError::AuthFailed`.
- **Detection**:
  - Gate output shows `reliability_replication_tests` status `fail`.
  - Auth failure counter reaches threshold, replica transitions to `failed` status.
  - SSM key rotation or IAM policy changes often precede this failure.
- **Triage**:
  1. Check SSM parameter validity for the affected node's API key (via `aws ssm get-parameter --name /fjcloud/nodes/<node_id>/api_key`).
  2. Verify IAM permissions allow SSM `GetParameter` for the replication service role.
  3. Confirm whether the SSM key matches the current active key on the flapjack VM (key may have been rotated externally without propagating).
- **Resolution**:
  1. Rotate the SSM node API key via the provisioning service's key-rotation path.
  2. Restart the replication orchestrator cycle to clear the auth failure counter and retry.
  3. Re-run the gate and confirm `reliability_replication_tests` returns pass.

### Scheduler no-capacity

- **Failure mode**: An overloaded index has no viable same-provider destination VM available for migration. The scheduler cannot place the migration and fires a `no_capacity_warning_sent` alert instead of proceeding.
- **Detection**:
  - Gate output shows `reliability_scheduler_tests` status `fail`.
  - Alternatively, a `no_capacity_warning_sent` alert fires in production with the overloaded index details.
  - Scheduler logs show repeated placement failures with no candidate VMs matching provider/region constraints.
- **Triage**:
  1. Review VM inventory utilization — check if all VMs in the affected region/provider are above `overload_threshold` (default 0.85).
  2. Confirm `max_concurrent_migrations` limit has not been reached (default 3 in-flight migrations).
  3. Check whether a cross-provider migration policy is in effect that is restricting candidate selection.
- **Resolution**:
  1. Provision additional VM capacity in the affected provider/region to create viable migration destinations.
  2. If immediate capacity is unavailable, adjust `overload_threshold` or `overload_duration_secs` temporarily to reduce trigger frequency.
  3. Once new VMs are provisioned and registered in VM inventory, the scheduler will automatically select them on the next cycle.
  4. Re-run the gate and confirm `reliability_scheduler_tests` returns pass.

### Security command injection detection

- **Failure mode**: Security scan detects unsafe `std::process::Command` usage with non-literal arguments.
- **Detection**:
  - `security_cmd_injection` check fails in gate output.
  - Failure reason includes `SECURITY_CMD_INJECTION_FOUND`.
- **Expected alert**: Aggregate/security gate reports check status `fail` with `SECURITY_CMD_INJECTION_FOUND`.
- **Triage**:
  1. Inspect reported file/line(s) and confirm command construction path.
  2. Determine whether user-controlled input can reach command args or executable path.
  3. Validate whether an allowlisted literal invocation pattern can replace dynamic command construction.
- **Resolution**:
  1. Refactor command execution to literal command paths and fixed arg templates.
  2. Add or update guard tests in `scripts/tests/security_checks_test.sh` if pattern changes.
  3. Re-run security and aggregate gates; confirm command-injection check passes.

### Load regression failure

- **Failure mode**: Load baseline comparison detects severe regression (`LOAD_REGRESSION_FAILURE`) due >50% latency degradation, >50% throughput drop, or error rate >5%.
- **Detection**:
  - `load_gate` check fails in reliability/aggregate gate output.
  - Failure reason includes `LOAD_REGRESSION_FAILURE`.
- **Expected alert**: Aggregate gate marks load sub-gate `fail` with explicit failing endpoint reason.
- **Triage**:
  1. Identify which endpoint(s) regressed (`health`, `search_query`, `index_create`, `admin_tenant_list`).
  2. Compare result JSON vs baseline JSON under `scripts/load/baselines/` and captured result artifacts.
  3. Check recent API/runtime/resource changes tied to affected endpoint path.
- **Resolution**:
  1. Fix the performance regression and rerun load harness.
  2. If behavior is an intentional performance shift, capture/approve new baseline in controlled review.
  3. Re-run aggregate gate; confirm load sub-gate returns pass or warning-only as expected.

### Provisioning auto-provision cleanup failure

- **Failure mode**: Partial `auto_provision_shared_vm` failure leaves orphaned SSM secrets, VMs, or DNS records.
- **Detection**:
  - Provisioning Stage 5 tests fail:
    - `auto_provision_shared_vm_cleans_up_ssm_on_vm_failure`
    - `auto_provision_shared_vm_cleans_up_vm_and_ssm_on_dns_failure`
    - `auto_provision_shared_vm_cleans_up_all_on_db_failure`
    - `auto_provision_shared_vm_cleans_up_vm_and_ssm_on_missing_public_ip`
- **Expected alert**: Reliability test suite reports provisioning cleanup-path failure.
- **Triage**:
  1. Audit orphaned assets: SSM key count, VM inventory/provider VMs, DNS records.
  2. Correlate failures to provisioning logs around SSM→VM→DNS→DB chain.
  3. Verify rollback/cleanup calls execute for each failure branch.
- **Resolution**:
  1. Remove orphaned resources and restore canonical state.
  2. Patch cleanup branch logic for failing step and add regression assertion if missing.
  3. Re-run provisioning tests and aggregate gate until green.

### Cold-tier restore download failure

- **Failure mode**: Restore path fails on object-store download and index tier does not recover cleanly from `restoring`.
- **Detection**:
  - `restore_download_failure_resets_tier_to_cold` or `restore_download_failure_does_not_corrupt_snapshot` test fails.
  - Restore jobs show status `failed` with `"download failed"` context.
- **Expected alert**: Warning alert fired for restore failure; aggregate/reliability test output indicates restore failure scenario regression.
- **Triage**:
  1. Verify object-store read permissions/network path for snapshot key.
  2. Check restore job state transition and tenant tier transition (`restoring` -> `cold`).
  3. Confirm snapshot metadata integrity (`status=completed`, object key/checksum unchanged).
- **Resolution**:
  1. Fix object-store/auth/connectivity issue and retry restore.
  2. Correct restore failure handling if tier reset or metadata preservation regressed.
  3. Re-run restore test suite and aggregate gate.

### Scheduler repo disconnect

- **Failure mode**: Scheduler `list_active` repo call fails (e.g., DB/repo disconnect), causing `SchedulerError::Repo`.
- **Detection**:
  - `run_cycle_handles_repo_list_active_failure_gracefully` fails.
  - Scheduler logs show repo/list-active failure messages.
- **Expected alert**: Reliability scheduler suite reports failure; aggregate reliability gate reflects scheduler test failure reason.
- **Triage**:
  1. Check DB/repo connectivity and connection pool saturation.
  2. Confirm scheduler can recover after transient repo failure (next cycle succeeds when dependency recovers).
  3. Validate no stale in-memory scheduler state blocks subsequent cycles.
- **Resolution**:
  1. Restore repo/DB connectivity and stabilize pool configuration.
  2. Restart scheduler process only if recovery does not occur automatically after dependency recovery.
  3. Re-run scheduler tests and aggregate gate to verify graceful recovery behavior.
