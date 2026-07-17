# Account Data Policy

## Beta launch policy

- This runbook is the canonical beta policy status owner for account data boundaries; use it to track what is implemented vs. not yet implemented.
- Customer self-service is export-only plus soft-delete:
  - authenticated `GET /account/export` is owned by `infra/api/src/routes/account.rs::export_account` and is triggered from `web/src/routes/dashboard/settings/+page.server.ts::actions.exportAccount`.
  - `DELETE /account` is owned by `infra/api/src/routes/account.rs::delete_account`, which enforces the `CustomerRepo::soft_delete retention boundary` (retained row plus deleted metadata for audit visibility).
- Lifecycle gaps are explicitly status-labeled:
  - hard erasure is implemented (admin-only; see Hard Erasure Contract below).
  - downstream cleanup is handled inline by the hard-erase transaction.
  - retention duration is automated by fjcloud-retention-job (see Retention Sweep Entrypoint below).
- Detailed deletion workflow and operator incident guidance remain in `docs/runbooks/account_deletion.md`; this runbook stays the single-source policy status surface.

## Current Deletion Contract

- `DELETE /account` is a password-confirmed soft-delete flow.
- The handler delegates account deletion to `CustomerRepo::soft_delete`.
- On first delete, soft delete updates `customers.status = 'deleted'`, stamps explicit deleted_at metadata, and retains the customer row for audit/retention tracking.
- retained audit rows are intentional and preserve operator/admin audit context.
- The cleanup read seam is `CustomerRepo::list_deleted_before_cutoff` / `PgCustomerRepo::list_deleted_before_cutoff`, which enumerates deleted rows before a retention cutoff.

## Authentication Behavior After Deletion

- A deleted account cannot authenticate.
- Post-delete login failures return the generic invalid-credentials body exactly as `{"error":"invalid email or password"}`.
- No token or customer-identifying payload is returned on that failure path.

## Admin Visibility Contract

- Admin tenant list and tenant detail views may continue to show deleted customer rows for audit purposes.
- This admin audit visibility is part of the current behavior contract and should be preserved.

## Hard Erasure Contract

- `POST /admin/customers/:id/hard-erase` is admin-only (`AdminAuth` required) and writes an `ACTION_CUSTOMER_HARD_ERASE` audit row before erasure.
- Precondition: customer must already be soft-deleted (`status = 'deleted'`). Active or suspended customers are rejected with `400 Bad Request`.
- On success: returns `204 No Content`. The customer row and all dependent data are permanently removed in a single transaction (api_keys, index_replicas, restore_jobs, cold_snapshots, storage_access_keys, storage_buckets, customer_tenants, customer_deployments, customer_rate_overrides, usage_records, usage_daily, audit_log, invoices, then customers; oauth_identities cascades via FK).
- Customers with open (unpaid) invoices are rejected with `409 Conflict` to preserve billing integrity.
- Repeat calls for an already-erased or unknown customer return `404 Not Found`.
- Owner: `CustomerRepo::hard_delete` in `infra/api/src/repos/pg_customer_repo.rs`, handler in `infra/api/src/routes/admin/tenants.rs::hard_erase_customer`.

## Retention Sweep Entrypoint

- `CustomerRepo::list_deleted_before_cutoff(cutoff: DateTime<Utc>)` returns soft-deleted customers whose `deleted_at` predates the cutoff, ordered oldest-first.
- The systemd timer `ops/systemd/fjcloud-retention-job.timer` runs `fjcloud-retention-job` daily on the API host.
- `fjcloud-retention-job` enumerates candidates through `CustomerRepo::list_deleted_before_cutoff` / `PgCustomerRepo::list_deleted_before_cutoff`, then delegates erasure to `POST /admin/customers/:id/hard-erase`.
- Default local/manual runs are dry-run unless `RETENTION_DRY_RUN=false` or `RETENTION_DRY_RUN=0` is supplied. Production deployment pins `RETENTION_DRY_RUN=0` in `ops/systemd/fjcloud-retention-job.service`.
- `RETENTION_MAX_ERASE_PER_RUN` bounds hard-erase attempts in each run. The summary JSON line includes `candidates`, `erased`, `failed`, and `skipped-by-bound`.
- Local dry-run example, using the existing env owners:

  ```bash
  cd infra && DATABASE_URL=... ADMIN_KEY=... API_URL=http://127.0.0.1:3001 cargo run -p retention-job --bin fjcloud-retention-job
  ```

  The local command stays dry-run by default and does not require a live purge override.
- API-host live probe:

  ```bash
  ENV=prod
  REGION=us-east-1
  INSTANCE_ID="$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=fjcloud-api-${ENV}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)"
  aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters commands='["systemctl status fjcloud-retention-job.timer --no-pager","journalctl -t fjcloud-retention-job -n 20 --no-pager"]'
  ```

  The EC2 selector contract is `Name=fjcloud-api-<env>` as used by `ops/scripts/deploy.sh` and `ops/scripts/rollback.sh`. Journald entries should use `SyslogIdentifier=fjcloud-retention-job` and include the machine-readable summary line with `candidates`, `erased`, `failed`, and `skipped-by-bound`.

## Export Surface

- Account export is implemented as the authenticated `GET /account/export` profile wrapper, exposed by `export_account` in `infra/api/src/routes/account.rs` and by the settings-page download action `actions.exportAccount` in `web/src/routes/dashboard/settings/+page.server.ts`.
