ALTER TABLE api_keys
    ADD COLUMN description TEXT,
    ADD COLUMN indexes TEXT[] NOT NULL DEFAULT '{}'::text[],
    ADD COLUMN restrict_sources TEXT[] NOT NULL DEFAULT '{}'::text[],
    ADD COLUMN expires_at TIMESTAMPTZ,
    ADD COLUMN max_hits_per_query INTEGER,
    ADD COLUMN max_queries_per_ip_per_hour INTEGER;
