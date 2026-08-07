-- The legacy column stores the provider-specific source connection identifier:
-- Algolia app ID, Meilisearch endpoint, or Typesense node URL. Preserve the
-- existing Algolia format while accepting non-empty hosted-provider values.
ALTER TABLE algolia_import_jobs
    DROP CONSTRAINT IF EXISTS algolia_import_jobs_algolia_app_id_check;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_source_connection_id_check
    CHECK (
        algolia_app_id IS NULL
        OR (source_provider = 'algolia' AND algolia_app_id ~ '^[A-Z0-9]+$')
        OR (
            source_provider IN ('meilisearch', 'typesense')
            AND LENGTH(BTRIM(algolia_app_id)) > 0
        )
    );
