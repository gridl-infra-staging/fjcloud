-- VM inventory: tracks physical VMs as distinct from per-customer logical deployments.
-- Multi-tenancy requires knowing what machines exist, their capacity, and current load.

CREATE TABLE vm_inventory (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    region       TEXT NOT NULL,
    provider     TEXT NOT NULL CHECK (provider IN ('aws', 'hetzner', 'gcp', 'bare_metal')),
    hostname     TEXT NOT NULL UNIQUE,
    flapjack_url TEXT NOT NULL,
    capacity     JSONB NOT NULL DEFAULT '{}',
    current_load JSONB NOT NULL DEFAULT '{}',
    status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'draining', 'decommissioned')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_vm_inventory_region_status ON vm_inventory (region, status);
