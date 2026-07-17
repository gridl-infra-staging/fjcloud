# Garage Object Storage — Operations Runbook

Garage v2.2.0 runs as a single-node S3-compatible backend on shared bare-metal.
Config reference and design decisions are in `ops/garage/README.md`.

| Item | Value |
|------|-------|
| Binary | `/usr/local/bin/garage` |
| Config | `/etc/garage/garage.toml` |
| Env file | `/etc/garage/env` |
| Metadata | `/var/lib/garage/meta` |
| Data | `/var/lib/garage/data` |
| S3 port | 3900 |
| Admin port | 3903 (localhost only) |
| Logs | `journalctl -u garage` |

## 1. First-Time Install

### 1.1. Run install script

```bash
sudo ops/garage/scripts/install-garage.sh
```

This downloads the pinned binary (SHA256-verified), creates the `garage` user/group,
sets up data directories, installs the systemd unit and sysctl config.

### 1.2. Review generated config

```bash
sudo cat /etc/garage/garage.toml
```

### 1.3. Start the service

```bash
sudo systemctl start garage
```

### 1.4. Initialize cluster

```bash
sudo ops/garage/scripts/init-cluster.sh
```

This assigns layout, creates the `cold-storage` bucket + S3 key, and writes
`/etc/garage/env` with credentials for application consumption.

### 1.5. Verify

```bash
sudo ops/garage/scripts/health-check.sh
```

Expected output:

```
systemd:  garage.service active
admin:    http://127.0.0.1:3903/health → 200 OK
s3:       http://127.0.0.1:3900/ → 403 OK

HEALTHY: all checks passed
```

**Production requirement**: Data directory (`/var/lib/garage/data`) should be on
XFS. The install script warns but does not block on ext4 (dev/staging is fine).

## 2. Health Checks

### 2.1. Quick service check

```bash
sudo systemctl status garage
```

### 2.2. Full health probe

```bash
sudo ops/garage/scripts/health-check.sh
```

Probes three endpoints:
- systemd: `garage.service` active
- Admin API: `GET http://127.0.0.1:3903/health` expects 200
- S3 API: `GET http://127.0.0.1:3900/` expects 200 or 403

Exit 0 = healthy, exit 1 = one or more checks failed.

### 2.3. Quiet mode (for cron/monitoring)

```bash
sudo ops/garage/scripts/health-check.sh -q
```

Only prints output on failure.

### 2.4. Cluster status

```bash
garage -c /etc/garage/garage.toml status
```

### 2.5. Verify layout

```bash
garage -c /etc/garage/garage.toml layout show
```

## 3. Config Changes

### 3.1. Edit the config

```bash
sudo vim /etc/garage/garage.toml
```

Key tuning parameters (see `ops/garage/README.md` for full reference):

| Key | Default | Notes |
|-----|---------|-------|
| `block_ram_buffer_max` | `"100MiB"` | Top-level; memory budget for block writes |
| `metadata_fsync` | `true` | Critical for single-node LMDB safety |
| `block_max_concurrent_reads` | `4` | Limit I/O on shared server |
| `block_max_concurrent_writes_per_request` | `3` | Limit I/O on shared server |

### 3.2. Validate syntax

```bash
# Restart and inspect startup logs; do not launch a second foreground server
# while the systemd unit is already holding the configured ports.
sudo systemctl restart garage
sudo journalctl -u garage -n 50 --no-pager
```

If the restart succeeds and the journal shows no config/TOML parse errors, the
config is valid.

### 3.3. Apply changes

```bash
sudo ops/garage/scripts/init-cluster.sh
```

Re-run `init-cluster.sh` after endpoint, region, or credential changes so
`/etc/garage/env` stays aligned with `garage.toml`.

### 3.4. Verify

```bash
sudo ops/garage/scripts/health-check.sh
```

## 4. Data Directory Maintenance

### 4.1. Check disk usage

```bash
df -h /var/lib/garage/data /var/lib/garage/meta
du -sh /var/lib/garage/data /var/lib/garage/meta
```

### 4.2. Check filesystem type

```bash
stat -f -c '%T' /var/lib/garage/data
```

Expected: `xfs` in production. See OQ-4 in `ops/garage/README.md`.

### 4.3. Check bucket stats

```bash
garage -c /etc/garage/garage.toml bucket info cold-storage
```

### 4.4. Verify directory ownership

```bash
ls -la /var/lib/garage/
```

Expected: `garage:garage` ownership on `data/` and `meta/`.

### 4.5. LMDB metadata snapshots

Garage auto-snapshots metadata every 6h:

```bash
ls -lt /var/lib/garage/meta/snapshots/
```

### 4.6. Recover from LMDB corruption

```bash
# 1. Stop garage
sudo systemctl stop garage

# 2. List available snapshots
ls -lt /var/lib/garage/meta/snapshots/

# 3. Restore from most recent snapshot (see Garage docs for procedure)

# 4. Restart
sudo systemctl start garage

# 5. Verify
sudo ops/garage/scripts/health-check.sh
```

## 5. Version Upgrades

### 5.1. Download new binary

```bash
curl -fsSL -o /tmp/garage-new \
  https://garagehq.deuxfleurs.fr/_releases/v<VERSION>/x86_64-unknown-linux-musl/garage
sha256sum /tmp/garage-new
```

### 5.2. Update pinned version and hash

Edit `ops/garage/scripts/install-garage.sh` — update `GARAGE_VERSION` and `GARAGE_SHA256`.
Update `ops/garage/README.md` pinned version section.

### 5.3. Stop, replace, start

```bash
sudo systemctl stop garage
sudo install -m 0755 /tmp/garage-new /usr/local/bin/garage
sudo systemctl start garage
```

### 5.4. Run migration if needed

Check release notes — if a migration is required:

```bash
garage -c /etc/garage/garage.toml migrate
```

### 5.5. Verify

```bash
sudo ops/garage/scripts/health-check.sh
garage -c /etc/garage/garage.toml status
```

## 6. Complete Removal

Garage is designed for clean removal when the custom engine replaces it.

### 6.1. Stop and disable

```bash
sudo systemctl stop garage
sudo systemctl disable garage
```

### 6.2. Remove systemd unit and sysctl config

```bash
sudo rm /etc/systemd/system/garage.service
sudo rm /etc/sysctl.d/99-garage.conf
sudo systemctl daemon-reload
sudo sysctl --system
```

### 6.3. Remove binary

```bash
sudo rm /usr/local/bin/garage
```

### 6.4. Remove config

```bash
sudo rm -rf /etc/garage
```

### 6.5. Remove data (DESTRUCTIVE — ensure data is migrated first)

```bash
sudo rm -rf /var/lib/garage
```

### 6.6. Remove user and group

```bash
sudo userdel garage
sudo groupdel garage
```

### 6.7. Verify removal

```bash
# All should return "not found" or similar
which garage
id garage
systemctl status garage
ls /etc/garage /var/lib/garage
```

## 7. Troubleshooting

### 7.1. Service won't start

```bash
systemctl status garage -l
```

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Config syntax error | Invalid TOML | Run `garage server` manually to see error |
| Port conflict | Another service on 3900/3901/3903 | `ss -tlnp \| grep -E '390[013]'` |
| Permission denied | Wrong ownership on data dirs | `sudo chown -R garage:garage /var/lib/garage` |

### 7.2. S3 API returns 5xx

```bash
garage -c /etc/garage/garage.toml status
garage -c /etc/garage/garage.toml layout show
df -h /var/lib/garage/data /var/lib/garage/meta
```

### 7.3. High I/O / slow co-located services

```bash
# Current dirty page state
cat /proc/vmstat | grep -E 'dirty|writeback'

# Verify sysctl values
sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs
# Expected: 10 / 5 / 1000

# If showing defaults (20/10/3000), re-apply:
sudo sysctl --system
```

### 7.4. Key/bucket management

```bash
# List keys
garage -c /etc/garage/garage.toml key list
# Inspect key
garage -c /etc/garage/garage.toml key info griddle-cold-storage
# Create additional key
garage -c /etc/garage/garage.toml key create <key-name>
garage -c /etc/garage/garage.toml bucket allow cold-storage --read --write --key <key-name>
```

## 8. Cold Tier Bridge Configuration

To point the application's cold tier pipeline at the local Garage instance,
map Garage infra vars (from `/etc/garage/env`) to the app-level `COLD_STORAGE_*`
and `AWS_*` variables. No Rust code changes are needed — `S3ObjectStore`
already supports arbitrary S3-compatible endpoints.

### 8.1. Set env var bridge

Add to the API server's environment (systemd `EnvironmentFile`, `.env`, or
shell profile):

```bash
# Source Garage credentials
source /etc/garage/env

# Map to application cold storage vars
export COLD_STORAGE_ENDPOINT="${GARAGE_S3_ENDPOINT}"
export COLD_STORAGE_REGION="${GARAGE_S3_REGION}"
export COLD_STORAGE_BUCKET="${GARAGE_S3_BUCKET}"

# Map to AWS SDK credentials (S3ObjectStore uses aws_config::defaults())
export AWS_ACCESS_KEY_ID="${GARAGE_S3_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${GARAGE_S3_SECRET_KEY}"
```

**Credential scoping warning:** Setting `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
to Garage credentials is safe only when the API server does not also need AWS
credentials for EC2/Route53/SSM on the same host. Bare-metal and Hetzner
deployments satisfy this. Mixed AWS + Garage deployments would require
per-client credential scoping (future work).

### 8.2. Verify connectivity

```bash
# Quick S3 list via curl (expect XML with bucket contents or empty list)
source /etc/garage/env
curl -s "http://127.0.0.1:3900/cold-storage" \
  --aws-sigv4 "aws:amz:${GARAGE_S3_REGION}:s3" \
  -u "${GARAGE_S3_ACCESS_KEY}:${GARAGE_S3_SECRET_KEY}" | head -20

# Or via AWS CLI (if installed)
AWS_ACCESS_KEY_ID="${GARAGE_S3_ACCESS_KEY}" \
AWS_SECRET_ACCESS_KEY="${GARAGE_S3_SECRET_KEY}" \
aws --endpoint-url "${GARAGE_S3_ENDPOINT}" --region "${GARAGE_S3_REGION}" \
  s3 ls "s3://${GARAGE_S3_BUCKET}/"
```

### 8.3. Rollback to AWS S3

Unset `COLD_STORAGE_ENDPOINT` to revert to the default AWS S3 backend:

```bash
unset COLD_STORAGE_ENDPOINT
unset COLD_STORAGE_REGION
unset COLD_STORAGE_BUCKET
# Restore AWS credentials to their original values if they were changed
```

Restart the API server after changing environment variables.

## 9. Resource Limits

The systemd unit enforces:

| Limit | Value | Rationale |
|-------|-------|-----------|
| MemoryMax | 512M | Shared server budget (bridge uses 50-200MB) |
| CPUQuota | 80% | Leave headroom for Postgres/flapjack |
| IOWeight | 50 | Below default (100), deprioritize vs DB |
| LimitNOFILE | 42000 | Sufficient for connection + file handles |

Adjust temporarily (until next restart):

```bash
sudo systemctl set-property garage.service MemoryMax=1G
```

Adjust permanently:

```bash
sudo vim /etc/systemd/system/garage.service
sudo systemctl daemon-reload
sudo systemctl restart garage
```

Validate on Linux before deploy:

```bash
systemd-analyze verify /etc/systemd/system/garage.service
```
