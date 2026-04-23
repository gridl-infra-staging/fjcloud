-- Object storage pricing: add object storage rates to rate_cards and extend
-- the invoice_line_items unit constraint for object storage line items.

ALTER TABLE rate_cards
    ADD COLUMN object_storage_rate_per_gb_month NUMERIC(10,6) NOT NULL DEFAULT 0.024000,
    ADD COLUMN object_storage_egress_rate_per_gb NUMERIC(10,6) NOT NULL DEFAULT 0.010000;

-- Seed the launch rate card with object storage pricing.
UPDATE rate_cards
    SET object_storage_rate_per_gb_month = 0.024000,
        object_storage_egress_rate_per_gb = 0.010000
    WHERE name = 'launch-2026';

-- Extend the unit CHECK constraint to allow object storage line item types.
ALTER TABLE invoice_line_items
    DROP CONSTRAINT IF EXISTS invoice_line_items_unit_check;

ALTER TABLE invoice_line_items
    ADD CONSTRAINT invoice_line_items_unit_check
    CHECK (unit IN ('requests_1k', 'write_ops_1k', 'gb_months', 'vm_hours', 'cold_gb_months', 'object_storage_gb_months', 'object_storage_egress_gb'));
