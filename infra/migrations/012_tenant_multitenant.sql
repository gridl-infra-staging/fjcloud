-- Extend customer_tenants for multi-tenancy: vm_id, tier, resource_quota.
-- vm_id is nullable initially — existing rows have no vm_id yet.

ALTER TABLE customer_tenants
    ADD COLUMN vm_id UUID REFERENCES vm_inventory(id),
    ADD COLUMN tier TEXT NOT NULL DEFAULT 'active' CHECK (tier IN ('active', 'migrating', 'pinned')),
    ADD COLUMN resource_quota JSONB NOT NULL DEFAULT '{}';

CREATE INDEX idx_customer_tenants_vm_id ON customer_tenants (vm_id);
