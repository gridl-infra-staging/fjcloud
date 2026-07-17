-- Stage 2 pricing contract migration: remove legacy search/write dimensions and
-- move hot-storage pricing from per-GB to per-MB naming and defaults.
--
-- No down migration is provided: this repository has no production data and the
-- Stage 1 contract change is intentionally breaking across API/billing layers.

ALTER TABLE rate_cards
    DROP COLUMN search_rate_per_1k,
    DROP COLUMN write_rate_per_1k;

ALTER TABLE rate_cards
    RENAME COLUMN storage_rate_per_gb_month TO storage_rate_per_mb_month;

ALTER TABLE rate_cards
    ALTER COLUMN storage_rate_per_mb_month SET DEFAULT 0.050000;

-- Normalize the seeded launch row to the flat hot-storage rate used by Stage 1.
UPDATE rate_cards
SET storage_rate_per_mb_month = 0.050000
WHERE name = 'launch-2026';
