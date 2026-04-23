-- Cold storage tiering: snapshots, restore jobs, and tier extension.
-- Extends customer_tenants with cold/restoring tiers, last_accessed_at tracking,
-- and cold_snapshot_id FK. Creates cold_snapshots and restore_jobs tables.

-- Extend tier CHECK to include cold and restoring states.
ALTER TABLE customer_tenants
    DROP CONSTRAINT IF EXISTS customer_tenants_tier_check;

ALTER TABLE customer_tenants
    ADD CONSTRAINT customer_tenants_tier_check
        CHECK (tier IN ('active', 'migrating', 'pinned', 'cold', 'restoring'));

-- Track last search/query activity for idle detection.
ALTER TABLE customer_tenants
    ADD COLUMN last_accessed_at TIMESTAMPTZ;

-- Cold snapshots: index data exported to object storage.
CREATE TABLE cold_snapshots (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  UUID NOT NULL REFERENCES customers(id),
    tenant_id    TEXT NOT NULL,
    source_vm_id UUID NOT NULL REFERENCES vm_inventory(id),
    object_key   TEXT NOT NULL,
    size_bytes   BIGINT NOT NULL DEFAULT 0,
    checksum     TEXT,
    status       TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'exporting', 'completed', 'failed', 'expired')),
    error        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ
);

-- Prevent duplicate active snapshots for the same index.
CREATE UNIQUE INDEX idx_cold_snapshots_active_per_index
    ON cold_snapshots (customer_id, tenant_id)
    WHERE status IN ('pending', 'exporting', 'completed');

-- For cold tier manager queries: find snapshots by status.
CREATE INDEX idx_cold_snapshots_status_created
    ON cold_snapshots (status, created_at);

-- FK from customer_tenants to cold_snapshots (set when index goes cold).
ALTER TABLE customer_tenants
    ADD COLUMN cold_snapshot_id UUID REFERENCES cold_snapshots(id);

-- Restore jobs: async restore of cold indexes back to active VMs.
CREATE TABLE restore_jobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    tenant_id       TEXT NOT NULL,
    snapshot_id     UUID NOT NULL REFERENCES cold_snapshots(id),
    dest_vm_id      UUID REFERENCES vm_inventory(id),
    status          TEXT NOT NULL DEFAULT 'queued'
                        CHECK (status IN ('queued', 'downloading', 'importing', 'completed', 'failed')),
    idempotency_key TEXT NOT NULL UNIQUE,
    error           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ
);

-- For restore job lookups by customer+index.
CREATE INDEX idx_restore_jobs_customer_tenant
    ON restore_jobs (customer_id, tenant_id);

-- For active job queries.
CREATE INDEX idx_restore_jobs_status
    ON restore_jobs (status);
