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
