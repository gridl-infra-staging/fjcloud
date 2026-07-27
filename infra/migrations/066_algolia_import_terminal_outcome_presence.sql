ALTER TABLE algolia_import_jobs
    ADD COLUMN terminal_outcome_observed BOOLEAN DEFAULT FALSE;

UPDATE algolia_import_jobs
SET terminal_outcome_observed = NULL
WHERE erased_at IS NOT NULL;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_terminal_outcome_observed_active_shape
    CHECK (
        (erased_at IS NULL AND terminal_outcome_observed IS NOT NULL)
        OR (erased_at IS NOT NULL AND terminal_outcome_observed IS NULL)
    );
