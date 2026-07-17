ALTER TABLE customers
ADD COLUMN quota_warnings_sent JSONB NOT NULL DEFAULT '{}'::jsonb;
