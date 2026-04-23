-- AllYourBase tenant instances managed by fjcloud_dev.
-- Stores local control-plane metadata only — no AYB admin credentials or ownerUserId.

CREATE TABLE ayb_tenants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    ayb_tenant_id   TEXT NOT NULL,
    ayb_slug        TEXT NOT NULL,
    ayb_cluster_id  TEXT NOT NULL,
    ayb_url         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'provisioning'
                        CHECK (status IN ('provisioning', 'ready', 'deleting', 'error')),
    plan            TEXT NOT NULL
                        CHECK (plan IN ('free', 'starter', 'pro', 'enterprise')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

-- One active AYB instance per customer (soft-deleted rows excluded).
CREATE UNIQUE INDEX uix_ayb_tenants_customer_active
    ON ayb_tenants (customer_id) WHERE deleted_at IS NULL;

-- One active slug per cluster (soft-deleted rows excluded).
CREATE UNIQUE INDEX uix_ayb_tenants_cluster_slug_active
    ON ayb_tenants (ayb_cluster_id, ayb_slug) WHERE deleted_at IS NULL;

-- Lookup by customer_id for list queries.
CREATE INDEX ix_ayb_tenants_customer_id
    ON ayb_tenants (customer_id);

-- Lookup active rows by status for admin/monitoring queries.
CREATE INDEX ix_ayb_tenants_status_active
    ON ayb_tenants (status) WHERE deleted_at IS NULL;
