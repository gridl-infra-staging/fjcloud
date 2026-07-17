-- Persisted alert history for the admin panel and operational review.
-- Populated by AlertService implementations (Slack, Log, Mock).
-- Retention: alerts older than 90 days can be pruned by a cron job (not automated in Stage 6).

CREATE TABLE alerts (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    severity         TEXT        NOT NULL,
    title            TEXT        NOT NULL,
    message          TEXT        NOT NULL,
    metadata         JSONB       NOT NULL DEFAULT '{}',
    delivery_status  TEXT        NOT NULL DEFAULT 'pending',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Recent alerts query (admin panel, GET /admin/alerts) always orders by created_at DESC.
CREATE INDEX idx_alerts_created_at ON alerts (created_at DESC);
