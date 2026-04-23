# Garage Object Storage — Ops Tooling

Garage is deployed as a bridge backend for Griddle Storage (S3-compatible object storage).
It will be swapped for a custom MIT-licensed engine later. The install is designed to be
cleanly removable.

## Design Decisions

### Pinned Version: v2.2.0

- **Latest stable release** as of 2026-01-24 (v2.x line on GitHub `deuxfleurs-org/garage`).
- v2.x includes the admin API v2 (`/v2/` endpoints), multiple admin tokens with scoping,
  and CLI-as-admin-API-client architecture.
- v1.x line (latest v1.3.1 on Gitea) is maintained separately; v2.x is the active line.
- **Binary URL**: `https://garagehq.deuxfleurs.fr/_releases/v2.2.0/x86_64-unknown-linux-musl/garage`
  (~42MB static musl binary).
- **No upstream SHA256 checksums**: Garage does not publish checksum files alongside
  releases (verified: no `.sha256sum` on download CDN, no checksums in `_releases.json`,
  no assets on Gitea releases). The install script pins a self-computed SHA256 from a
  verified download. Update the hash when bumping versions.
- **Pinned SHA256** (computed 2026-03-15 from verified HTTPS download, 43,752,568 bytes,
  ELF 64-bit x86-64 static-pie musl binary):
  ```
  ec761bb996e8453e86fe68ccc1cf222c73bb1ef05ae0b540bd4827e7d1931aab
  ```

### XFS for Data, Metadata on Same Filesystem (Practical)

- **Data directory** (`/var/lib/garage/data`): XFS recommended by Garage docs — ext4 has
  stricter inode limits that cause issues with large object counts.
- **Metadata directory** (`/var/lib/garage/meta`): Garage docs recommend BTRFS/ZFS for
  checksumming, but we use the same XFS partition with `metadata_fsync = true` to avoid
  requiring a separate filesystem. Single-node deployment means no replication recovery,
  so fsync + auto-snapshots are our corruption mitigation.
- `metadata_auto_snapshot_interval = "6h"` for recovery capability.

### Single-Node, replication_factor = 1

- Bridge backend — will be replaced. No need for multi-node complexity.
- Means zero tolerance for node failure (acceptable: Garage is not the source of truth
  for customer data long-term, and cold tier has its own backup strategy).
- `consistency_mode = "consistent"` (default) is fine with factor=1.

### Port Assignments (Garage Defaults)

| Port | Service          | Bind Address     | Notes                                |
|------|------------------|------------------|--------------------------------------|
| 3900 | S3 API           | `0.0.0.0:3900`  | Customer-facing (via Griddle proxy)  |
| 3901 | RPC (inter-node) | `[::]:3901`     | Unused in single-node, still needed  |
| 3903 | Admin API        | `127.0.0.1:3903`| Localhost only — used by init scripts|

### systemd Service Type: simple (NOT notify)

- Garage does **not** implement sd_notify (no `sd-notify` crate in Cargo.lock, official
  docs default to `Type=simple`).
- Using `Type=notify` would cause systemd to wait for a `READY=1` signal that never
  arrives, leading to startup timeout and service failure.
- Use `Type=simple` to match Garage's actual behavior.

### db_engine: lmdb

- LMDB is the fastest and most tested engine per Garage docs.
- Alternatives: `sqlite` (more robust after unclean shutdown), `fjall` (experimental).
- LMDB is vulnerable to corruption on unclean shutdown — mitigated by `metadata_fsync = true`
  and `metadata_auto_snapshot_interval = "6h"`.

## garage.toml Config Keys Reference

All block/performance keys are **top-level** (not under a `[block_manager]` section).

### Top-Level Keys

| Key | Value | Rationale |
|-----|-------|-----------|
| `metadata_dir` | `/var/lib/garage/meta` | SSD-backed for performance |
| `data_dir` | `/var/lib/garage/data` | XFS filesystem, large partition |
| `db_engine` | `"lmdb"` | Fastest, most tested |
| `replication_factor` | `1` | Single-node bridge deployment |
| `metadata_fsync` | `true` | Single-node = no replication recovery; fsync prevents corruption |
| `data_fsync` | `false` | Acceptable risk for data blocks; Garage checksums them |
| `metadata_auto_snapshot_interval` | `"6h"` | Recovery from LMDB corruption |
| `block_size` | `"1MiB"` | Default, fine for general use |
| `block_ram_buffer_max` | `"100MiB"` | Conservative for shared server (default 256MiB) |
| `block_max_concurrent_reads` | `4` | Limit I/O pressure on shared HDD |
| `block_max_concurrent_writes_per_request` | `3` | Default, safe for HDD |
| `compression_level` | `1` | Default zstd level, good compression/speed tradeoff |
| `lmdb_map_size` | `"1TiB"` | Default on 64-bit, virtual memory reservation |
| `rpc_bind_addr` | `"[::]:3901"` | Required even for single-node |
| `rpc_secret` | (generated) | `openssl rand -hex 32` — stored in config, not env |

### [s3_api] Section

| Key | Value | Rationale |
|-----|-------|-----------|
| `api_bind_addr` | `"0.0.0.0:3900"` | Accept connections from Griddle proxy |
| `s3_region` | `"garage"` | Arbitrary region name for S3 API |

### [admin] Section

| Key | Value | Rationale |
|-----|-------|-----------|
| `api_bind_addr` | `"127.0.0.1:3903"` | Localhost only for security |
| `admin_token` | (generated) | `openssl rand -base64 32` — written to `/etc/garage/env` by init script |

## sysctl Tuning (Dirty Page Cache)

These are **system-wide** settings that affect all filesystems, not just XFS.
Purpose: prevent Garage from filling the kernel dirty page cache and starving
co-located services (Postgres, flapjack, API server).

| Parameter | Value | Default | Rationale |
|-----------|-------|---------|-----------|
| `vm.dirty_ratio` | `10` | `20` | Hard ceiling: processes block on write() at 10% RAM dirty. Prevents Garage bulk uploads from consuming all page cache. |
| `vm.dirty_background_ratio` | `5` | `10` | Background flush starts at 5% RAM dirty. Keeps writeback continuous and prevents I/O spikes that would impact Postgres. |
| `vm.dirty_expire_centisecs` | `1000` | `3000` | Dirty pages older than 10s get flushed (vs 30s default). Reduces data-at-risk window after crash. |

**Note**: Garage's own docs do not recommend specific sysctl tuning. These values are
our own hardening for shared bare-metal servers running multiple services. The values
match common PostgreSQL shared-server recommendations (Percona, EnterpriseDB).

## Resolved Open Questions

These decisions were made during Stage 1 research (2026-03-15) and apply to all build
sprints. Each references the checklist OPEN QUESTION it resolves.

### OQ-1: Checksum trust model — repo-pinned SHA256 vs signed manifest

**Decision**: Repo-pinned SHA256 is sufficient for Stage 1.

The binary is fetched over HTTPS from the official Garage CDN. No upstream checksums
exist (verified across `_releases.json`, Gitea assets, GitHub releases). The install
script pins a SHA256 computed from a verified initial download. This provides tamper
detection for subsequent installs. A signed manifest adds complexity without meaningful
security gain — the CDN is the trust root either way. Revisit if Garage starts publishing
checksums or if we move to an air-gapped deployment model.

### OQ-2: lmdb_map_size — conservative vs future-proof

**Decision**: Keep the default `"1TiB"` (64-bit default).

LMDB uses `mmap()` so this is a virtual address space reservation, not physical memory
allocation. Even millions of objects produce metadata in the low-GB range. 1TiB is the
upstream default and costs nothing. No reason to override.

### OQ-3: Ratio-based vs absolute dirty_bytes

**Decision**: Keep ratio-based (`vm.dirty_ratio=10`, `vm.dirty_background_ratio=5`).

Our bare-metal servers have consistent RAM (32-64GB), so ratios map to predictable
absolute values (3.2-6.4GB at 10%). Absolute `dirty_bytes` would be better with wildly
varying host sizes, but we don't have that. Ratio-based is simpler to reason about and
matches Percona/EnterpriseDB PostgreSQL tuning guides.

### OQ-4: XFS check in install script — hard-fail vs warn-only

**Decision**: Warn-only with logger message.

Garage docs say XFS is "recommended" for data partitions due to ext4 inode limits, but
it is not required. Hard-failing blocks dev/staging on ext4. The install script logs a
warning via `logger -t garage-install` and continues. The runbook documents XFS as a
production requirement. Source: Garage "Real-world deployment" cookbook.

### OQ-5: data_fsync=true for durability parity

**Decision**: Keep `data_fsync = false` (default).

Data blocks are checksummed by Garage and detectable via scrub. In single-node, a lost
block means re-upload — acceptable for a bridge backend. `data_fsync=true` would halve
write throughput with marginal benefit. Metadata is what must survive (fsync=true there).

### OQ-6: Static User=garage vs DynamicUser=true

**Decision**: Static `User=garage` with explicit system user creation.

The upstream systemd example uses `DynamicUser=true` with `StateDirectory=garage`, which
stores data at `/var/lib/private/garage` (bind-mounted). This works for simple setups but:
- UIDs are ephemeral — complicates manual data directory inspection and maintenance
- Conflicts with our install script which `useradd --system` and `chown`s data dirs
- Our ops pattern (flapjack.service) uses static users for all services

Static user gives stable ownership, predictable paths, and ops consistency.

### OQ-7: Gate sysctl install to dedicated hosts

**Decision**: Install sysctl conf unconditionally.

The values (10/5/1000) are strictly more conservative than kernel defaults (20/10/3000).
They reduce dirty page accumulation, which benefits all co-located services. There's no
downside — lower dirty thresholds only mean more frequent, smaller flushes. The sysctl
file installs to `/etc/sysctl.d/99-garage.conf` and is cleanly removable.

### OQ-8: Containerized systemd-analyze verify

**Decision**: Not for Stage 1.

Manual directive review against `systemd.service(5)` is sufficient. The runbook documents
running `systemd-analyze verify` on a Linux host before production deployment. A Docker-based
validation helper is over-engineering for a single unit file.

### OQ-9: Bootstrap token — root admin_token vs scoped token

**Decision**: Use the root `admin_token` from `garage.toml` for bootstrap.

The init script runs once on first deploy. The admin_token is already configured in
garage.toml. Scoped tokens (v2.0+ feature) are for ongoing operational access with
least-privilege — not needed until we have multiple admin tools. Keep it simple.

### OQ-10: Health script S3 probe — accept 200|403

**Decision**: Accept HTTP 200 or 403 as healthy on S3 endpoint.

- `403` = S3 API is up, auth required (expected for unauthenticated probe)
- `200` = unlikely without auth but harmless to accept
- Connection refused / timeout = down

This is robust against front-proxy or auth configuration changes.

### OQ-11: COLD_STORAGE_* and GARAGE_* coexistence

**Decision**: Keep both indefinitely. No deprecation plan needed.

`COLD_STORAGE_*` is the application-level abstraction (used by `ObjectStore` trait in
`services/object_store.rs`). `GARAGE_*` is infrastructure-level config (Garage admin token,
endpoints). They serve different layers. Stage 2 bridges them by setting
`COLD_STORAGE_ENDPOINT=$GARAGE_S3_ENDPOINT`. No collision, no redundancy.

### OQ-12: Mount-type check during install (same as OQ-4)

See OQ-4. Warn-only, not hard-fail.

## Directory Layout

```
ops/garage/
├── README.md                    # This file — design decisions + config reference
├── garage.toml.template         # Parameterized Garage config
├── garage.service               # systemd unit with resource limits
├── sysctl-garage.conf           # Kernel tuning for shared-server safety
└── scripts/
    ├── install-garage.sh        # Download binary, create user/dirs, install unit
    ├── init-cluster.sh          # Initialize layout, create admin key + bucket
    └── health-check.sh          # Probe admin + S3 APIs
```
