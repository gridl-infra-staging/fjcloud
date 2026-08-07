-- When the engine reports a retained import as unavailable, the row keeps its
-- node import reservation while reconciliation retries. Without a start mark
-- that retry is unbounded, so an import the engine has permanently forgotten
-- holds its reservation forever and eventually wedges the node against the
-- active node import limit. This column records when the current continuous
-- run of `backend_unavailable` began; state writes reset it as soon as the
-- engine answers with anything else.
ALTER TABLE algolia_import_jobs
    ADD COLUMN IF NOT EXISTS engine_unavailable_since TIMESTAMPTZ;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_engine_unavailable_since_check
    CHECK (
        engine_unavailable_since IS NULL
        OR error_code = 'backend_unavailable'
    );
