# Database Backup & Recovery

## Strategy overview

| Parameter                      | Value                                                                        |
| ------------------------------ | ---------------------------------------------------------------------------- |
| RPO (Recovery Point Objective) | 1 hour (WAL archiving between daily backups)                                 |
| RTO (Recovery Time Objective)  | 4 hours                                                                      |
| Retention                      | 30 days for daily backups                                                    |
| Method                         | AWS RDS automated backups (preferred) or pg_basebackup + WAL archiving to S3 |

## Option A: AWS RDS (recommended)

If using AWS RDS for Postgres, automated backups and PITR are built-in.

### Configuration

1. **Enable automated backups**: RDS console -> DB instance -> Modify -> Backup retention period: 30 days
2. **Backup window**: Set to a low-traffic period (for example, 04:00-05:00 UTC)
3. **Enable PITR**: Automatically enabled when backup retention is >0 days
4. **Enable deletion protection**: RDS console -> Modify -> Enable deletion protection

### Restore drill (script first)

Use the guarded script as the primary interface. Base command pattern:
`bash ops/scripts/rds_restore_drill.sh staging|prod --source-db-instance-id <source-db> --target-db-instance-id <target-db> [--snapshot-id <snapshot>] [--restore-time <timestamp>]`

By default the script is dry-run and prints the AWS restore command without dispatching it.

Snapshot-mode dry-run example:

```bash
bash ops/scripts/rds_restore_drill.sh staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore-20260422 \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22-03-00
```

Point-in-time dry-run example:

```bash
bash ops/scripts/rds_restore_drill.sh staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore-20260422-pitr \
  --restore-time 2026-04-22T03:15:00Z
```

The script requires exactly one restore mode selector (`--snapshot-id` or `--restore-time`).
The source and target DB instance identifiers must be different.

### Gated live execution (operator-only)

Live AWS dispatch is blocked unless the operator sets `RDS_RESTORE_DRILL_EXECUTE=1`.
The variable is documented in `docs/env-vars.md` under the AWS environment table.

```bash
RDS_RESTORE_DRILL_EXECUTE=1 \
bash ops/scripts/rds_restore_drill.sh staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore-20260422 \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22-03-00
```

### Restore contract and monitoring

- The script follows AWS new-instance restore APIs:
  - Snapshot mode: `restore-db-instance-from-db-snapshot` with `--db-instance-identifier <target>` and `--db-snapshot-identifier <snapshot>`
  - PITR mode: `restore-db-instance-to-point-in-time` with `--source-db-instance-identifier <source>`, `--target-db-instance-identifier <target>`, and `--restore-time <timestamp>`
- Keep source and target identifiers distinct to avoid accidental replacement.
- AWS Console and CloudWatch checks are secondary monitoring only; the script command contract remains the source of truth.
- If a wrapper-managed run ends with `status=blocked` or `status=fail` before the target reaches `available`, treat the run as a blocker report rather than restore proof.
- For those pre-`available` outcomes, status docs should report the attempt date, wrapper verdict, reason, target status, and cleanup result without claiming proof and without writing a canonical verification file under `docs/runbooks/evidence/database-recovery/`.

## Restore verification and evidence (required)

After AWS reports the target instance as available, connect to the restored target endpoint and run sanity queries.

```bash
# Example: capture a single evidence log with all query results.
psql "postgres://<user>:<password>@<restored-target-endpoint>:5432/<db_name>" <<'SQL' | tee docs/runbooks/evidence/database-recovery/20260422T031500Z_staging_restore_verification.txt
SELECT COUNT(*) FROM tenants;
SELECT COUNT(*) FROM invoices WHERE created_at > now() - interval '7 days';
SELECT COUNT(*) FROM deployments WHERE status = 'running';
SELECT COUNT(*) FROM usage_records WHERE recorded_at > now() - interval '1 day';
SQL
```

Verification requirements:

- `tenants` count must be nonzero for environments with seeded or live tenants.
- `deployments` running count must match the known expected environment state at drill time.
- Recent invoices and usage rows should be nonzero when billing or metering activity exists in the selected recovery window.
- Store command output and notes under `docs/runbooks/evidence/database-recovery/`.
- Status docs may claim restore proof only when this evidence path contains captured sanity-query output from a real gated execution that reached `available`.
- The staging run attempted on `2026-04-22` ended with a wrapper `fail` verdict while the target remained `backing-up`, so it does not satisfy the restore-proof contract.

## Cutover boundaries (drill only)

For restore drills, the runbook boundaries are strict:

- The drill must not mutate `/fjcloud/<env>/database_url`.
- The drill must not restart services.
- The drill must not update `DATABASE_URL`.
- Production cutover is a separate incident-command decision after verification evidence is reviewed.

## Option B: Manual pg_basebackup + WAL archiving

For self-managed Postgres (not RDS).

### Daily base backup (cron job)

```bash
#!/bin/bash
# /etc/cron.d/fjcloud-backup - runs daily at 03:00 UTC
BACKUP_BUCKET="s3://fjcloud-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

pg_basebackup -h localhost -U fjcloud_backup -D /tmp/pg_backup_$TIMESTAMP -Ft -z -P
aws s3 cp /tmp/pg_backup_$TIMESTAMP/base.tar.gz "$BACKUP_BUCKET/base/$TIMESTAMP/"
rm -rf /tmp/pg_backup_$TIMESTAMP
```

### WAL archiving

Add to `postgresql.conf`:

```text
archive_mode = on
archive_command = 'aws s3 cp %p s3://fjcloud-backups/wal/%f'
```

### Restoring from base backup

```bash
# 1. Stop Postgres
sudo systemctl stop postgresql

# 2. Download the backup
aws s3 cp s3://fjcloud-backups/base/<TIMESTAMP>/base.tar.gz /tmp/restore/
cd /var/lib/postgresql/data
tar xzf /tmp/restore/base.tar.gz

# 3. Create recovery.conf for PITR (optional)
cat > /var/lib/postgresql/data/recovery.conf <<'EOF2'
restore_command = 'aws s3 cp s3://fjcloud-backups/wal/%f %p'
recovery_target_time = '2026-02-21 14:00:00 UTC'
EOF2

# 4. Start Postgres
sudo systemctl start postgresql
```

## S3 bucket structure

```text
s3://fjcloud-backups/
|- base/
|  |- 20260220_030000/
|  |  \- base.tar.gz
|  \- 20260221_030000/
|     \- base.tar.gz
\- wal/
   |- 000000010000000000000001
   |- 000000010000000000000002
   \- ...
```

## Access control

- Backup S3 bucket: restricted to the backup IAM role and ops team
- RDS snapshots: restricted to the AWS account DB admin IAM policies
- Encryption: enable at-rest encryption on S3 bucket and RDS instance
