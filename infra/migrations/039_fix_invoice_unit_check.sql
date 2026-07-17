-- Fix invoice_line_items_unit_check to include mb_months.
-- Migration 036 renamed the storage dimension from per-GB to per-MB but did not
-- update this constraint, so invoice generation with the new unit fails.

ALTER TABLE invoice_line_items
    DROP CONSTRAINT invoice_line_items_unit_check;

ALTER TABLE invoice_line_items
    ADD CONSTRAINT invoice_line_items_unit_check CHECK (
        unit = ANY (ARRAY[
            'mb_months',
            'gb_months',
            'vm_hours',
            'cold_gb_months',
            'object_storage_gb_months',
            'object_storage_egress_gb'
        ])
    );
