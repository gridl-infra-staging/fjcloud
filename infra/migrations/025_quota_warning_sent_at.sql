-- Track last time a free-tier quota warning email was sent.
ALTER TABLE customers
    ADD COLUMN quota_warning_sent_at TIMESTAMPTZ NULL;
