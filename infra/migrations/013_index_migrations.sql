-- Index migration tracker for Stage 7 zero-downtime moves.
-- NOTE: table name is `index_migrations` to avoid colliding with DB migration tooling names.

CREATE TABLE index_migrations (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    index_name   TEXT NOT NULL,
    customer_id  UUID NOT NULL,
    source_vm_id UUID NOT NULL REFERENCES vm_inventory(id),
    dest_vm_id   UUID NOT NULL REFERENCES vm_inventory(id),
    status       TEXT NOT NULL DEFAULT 'pending',
    requested_by TEXT NOT NULL,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    error        TEXT,
    metadata     JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_index_migrations_status ON index_migrations (status);
CREATE INDEX idx_index_migrations_index_name ON index_migrations (index_name);
