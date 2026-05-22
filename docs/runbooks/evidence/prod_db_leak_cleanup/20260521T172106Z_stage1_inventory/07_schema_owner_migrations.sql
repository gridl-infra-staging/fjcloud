-- Customers: one row per paying account.
CREATE TABLE customers (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT        NOT NULL,
    email               TEXT        NOT NULL UNIQUE,
    stripe_customer_id  TEXT,
    status              TEXT        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'suspended', 'deleted')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_customers_email  ON customers(email);
CREATE INDEX idx_customers_status ON customers(status);
-- Deployments: one per customer VM / flapjack node.
CREATE TABLE customer_deployments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID        NOT NULL REFERENCES customers(id),
    node_id         TEXT        NOT NULL UNIQUE, -- stable name used in metering keys
    region          TEXT        NOT NULL,
    vm_type         TEXT        NOT NULL,        -- e.g. 't4g.small'
    vm_provider     TEXT        NOT NULL         -- 'aws' | 'hetzner' | 'gcp' | 'bare_metal'
                        CHECK (vm_provider IN ('aws', 'hetzner', 'gcp', 'bare_metal')),
    ip_address      TEXT,
    status          TEXT        NOT NULL DEFAULT 'provisioning'
                        CHECK (status IN ('provisioning', 'running', 'stopped', 'terminated')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    terminated_at   TIMESTAMPTZ
);

CREATE INDEX idx_deployments_customer ON customer_deployments(customer_id);
CREATE INDEX idx_deployments_status   ON customer_deployments(status);

-- customer_tenants: maps flapjack index names (tenant_id) to customers.
-- One customer can have many indexes; one index belongs to exactly one customer.
CREATE TABLE customer_tenants (
    customer_id     UUID NOT NULL REFERENCES customers(id),
    tenant_id       TEXT NOT NULL,               -- the flapjack index name
    deployment_id   UUID NOT NULL REFERENCES customer_deployments(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (customer_id, tenant_id)
);

CREATE INDEX idx_tenants_deployment ON customer_tenants(deployment_id);
CREATE INDEX idx_tenants_tenant_id  ON customer_tenants(tenant_id);
-- Extend customer_deployments for provisioning automation.
-- New columns for cloud provider instance tracking, DNS, and health monitoring.

ALTER TABLE customer_deployments ADD COLUMN provider_vm_id TEXT;
ALTER TABLE customer_deployments ADD COLUMN hostname TEXT;
ALTER TABLE customer_deployments ADD COLUMN flapjack_url TEXT;
ALTER TABLE customer_deployments ADD COLUMN last_health_check_at TIMESTAMPTZ;
ALTER TABLE customer_deployments ADD COLUMN health_status TEXT NOT NULL DEFAULT 'unknown';

-- Add 'failed' to the status check constraint.
ALTER TABLE customer_deployments DROP CONSTRAINT IF EXISTS customer_deployments_status_check;
ALTER TABLE customer_deployments ADD CONSTRAINT customer_deployments_status_check
    CHECK (status IN ('provisioning', 'running', 'stopped', 'terminated', 'failed'));

-- Partial index for health monitor queries (only active deployments).
CREATE INDEX idx_deployments_active ON customer_deployments(status)
    WHERE status != 'terminated';
-- Soft-delete support for the customers table. The deleted_at column was
-- originally inlined into 001_customers.sql, which broke sqlx's "applied
-- migrations are immutable" invariant on environments that had already
-- applied 001 (e.g. the 2026-04-09 staging deploy). Reverting 001 to its
-- originally-applied form and adding the deleted_at change as a new
-- migration here keeps the migration history checksum-stable.
--
-- pg_customer_repo.rs reaper queries (find_soft_deleted_due_for_purge,
-- soft_delete_customer) rely on this column existing, so this migration
-- must apply before the new API binary is exposed to traffic.

ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_customers_deleted_at
    ON customers(deleted_at);
