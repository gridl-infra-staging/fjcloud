# Staging API DB Visibility Diagnosis

PURPOSE: Diagnose the staging API database visibility split using live receipts only. This bundle does not edit product code, probes, host configuration, or billing/Stripe/dunning state.

## Primary Outcome

Primary classification: WHERE-clause/mutation-expectation mismatch, not wrong-DB visibility.

The current live receipts do not reproduce a database visibility split. The API process, `/etc/fjcloud/env`, and canonical SSM database parameter all fingerprint to the same database URL endpoint and sha256 prefix. The shared SQL probe path can read a newly registered staging customer by both `id` and `email`, including the exact WHERE/result expressions used by the verify-email and password-reset clickthrough probes.

If a clickthrough probe still fails after this point, this evidence routes the remaining defect away from `ops/scripts/lib/generate_ssm_env.sh` and `scripts/launch/ssm_exec_staging.sh` database-source ownership. The next owner should be the mutation-specific path under `infra/api/src/repos/pg_customer_repo/` only after a fresh clickthrough receipt proves the expected mutation is missing despite row visibility.

## Evidence

- Live-state probe: `live_state_pointer.md` records `bash scripts/probe_live_state.sh` exit code `0` and source bundle `docs/live-state/20260712T185310Z`.
- Existing live RDS path: `staging_rds.txt` reports `376` non-deleted customers and `14` test-pattern customers through `scripts/launch/ssm_exec_staging.sh`.
- Running staging API targets: `ec2_running_instances.md` records exactly one running `fjcloud-api-staging` EC2 instance, `i-0fbc6d6bbbc8bdc6d`, with SSM ping `Online`. This rules out current multi-target selection drift from `scripts/launch/ssm_exec_staging.sh:35-40`.
- Per-instance env fingerprints: `instance_database_fingerprints.md` shows `/etc/fjcloud/env` and `/proc/<MainPID>/environ` both point to `fjcloud-staging.cabwlew6jcjl.us-east-1.rds.amazonaws.com:5432/fjcloud` with `sha256_16=a377bb0163e33e75`. `systemctl show --property=Environment fjcloud-api` is `MISSING`, consistent with `ops/systemd/fjcloud-api.service:19` using `EnvironmentFile=-/etc/fjcloud/env` rather than inline `Environment=`.
- Canonical SSM fingerprint: `canonical_ssm_database_fingerprint.md` shows `/fjcloud/staging/database_url` has the same endpoint and `sha256_16=a377bb0163e33e75`. The SSM suffix-to-env mapping is `ops/scripts/lib/generate_ssm_env.sh:45-50`.
- Shared SQL endpoint: `control_sql_endpoint.md` records selected target `i-0fbc6d6bbbc8bdc6d` immediately before the control query, and the read path returned `10.0.10.94/32:5432/fjcloud`.
- Throwaway API registration: `registration_receipt.md` records HTTP `201`, probe email `stage1db202607121858507126@test.flapjack.foo`, and customer id `abc9d7db-bf74-4cdf-949b-3135f61b8bab`.
- Row visibility: `customer_visibility_receipts.md` shows the shared SQL probe returned the expected email by id and expected id by email on both attempts separated by 2 seconds.
- Exact probe WHERE expressions: `exact_probe_where_receipts.md` shows the verify-email expression returned `false` by email and the password-reset expression returned `cleared` by id. Those are valid pre-clickthrough/pre-reset values and prove the row is visible through the same WHERE patterns.

## Ruled-Out Outcomes

- Wrong-DB visibility: ruled out by matching canonical SSM, env file, process env, and successful control-row reads.
- Multiple target selection drift: ruled out for this point in time because only one running `fjcloud-api-staging` target exists.
- Stale process environment: ruled out because `/proc/<MainPID>/environ` matches `/etc/fjcloud/env` and canonical SSM.
- Stale `/etc/fjcloud/env`: ruled out by matching canonical SSM.
- Canonical SSM drift: ruled out by matching instance fingerprints.
- Replica/read lag: ruled out because the row was visible immediately and after the repeated 2-second poll.
- Real product mutation defect: not proven by this stage because the throwaway control did not perform a verify-email clickthrough or password-reset mutation.

## Stage 3 Owner

No Stage 3 database-visibility owner is supported by the current receipts.

Conditional routing:

- If a future receipt proves `/etc/fjcloud/env` diverges from `/fjcloud/staging/database_url`, route to `ops/scripts/lib/generate_ssm_env.sh`.
- If multiple running `fjcloud-api-staging` instances exist and fingerprints diverge, route to `scripts/launch/ssm_exec_staging.sh`.
- If API and probe are intentionally configured to different database sources, route to the probe DB source owner.
- If mutation-specific clickthrough receipts prove `email_verified_at` or `password_reset_token` is not changed while row visibility still succeeds, route to `infra/api/src/repos/pg_customer_repo/` and the corresponding API mutation handler.

## Open Questions

Open questions: none for the Stage 1 database visibility diagnosis.
