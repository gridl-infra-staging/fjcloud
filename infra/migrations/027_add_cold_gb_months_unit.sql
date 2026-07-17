-- Add 'cold_gb_months' to the invoice_line_items unit CHECK constraint.
-- The billing engine (pricing.rs) generates line items with unit = 'cold_gb_months'
-- for cold storage, but migration 005 only allows: requests_1k, write_ops_1k,
-- gb_months, vm_hours — causing CHECK constraint violations on INSERT.

ALTER TABLE invoice_line_items
    DROP CONSTRAINT IF EXISTS invoice_line_items_unit_check;

ALTER TABLE invoice_line_items
    ADD CONSTRAINT invoice_line_items_unit_check
    CHECK (unit IN ('requests_1k', 'write_ops_1k', 'gb_months', 'vm_hours', 'cold_gb_months'));
