-- Track freshness of scheduler load scrapes for placement decisions.
-- NULL means the VM has never been scraped by scheduler yet.
ALTER TABLE vm_inventory
    ADD COLUMN load_scraped_at TIMESTAMPTZ;
