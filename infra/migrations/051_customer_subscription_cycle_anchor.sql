ALTER TABLE customers
ADD COLUMN IF NOT EXISTS subscription_cycle_anchor_at TIMESTAMPTZ NULL;
