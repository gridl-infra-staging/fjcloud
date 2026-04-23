ALTER TABLE customer_tenants
    ADD COLUMN service_type TEXT NOT NULL DEFAULT 'flapjack';

CREATE INDEX idx_tenants_service_type ON customer_tenants(service_type);
