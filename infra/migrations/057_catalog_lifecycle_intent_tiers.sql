-- Catalog lifecycle operation intents must be durable but not discoverable.
-- Extend only the canonical tenant tier constraint; route/service code owns
-- when these states are entered and published back to active/cold states.
ALTER TABLE customer_tenants
    DROP CONSTRAINT IF EXISTS customer_tenants_tier_check;

ALTER TABLE customer_tenants
    ADD CONSTRAINT customer_tenants_tier_check
        CHECK (tier IN (
            'active',
            'migrating',
            'pinned',
            'cold',
            'restoring',
            'provisioning',
            'deleting'
        ));
