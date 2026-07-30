-- 056 and 068 are already-applied history, so widening the durable
-- source-provider union must be a forward-only constraint migration.
ALTER TABLE algolia_import_jobs
    DROP CONSTRAINT IF EXISTS algolia_import_jobs_source_provider_check;

DO $$
DECLARE
    source_provider_constraint TEXT;
BEGIN
    SELECT conname INTO source_provider_constraint
    FROM pg_constraint
    WHERE conrelid = 'algolia_import_jobs'::regclass
      AND contype = 'c'
      AND conname <> 'algolia_import_jobs_public_or_erased_tombstone_shape'
      AND pg_get_constraintdef(oid) LIKE '%source_provider%'
      AND pg_get_constraintdef(oid) LIKE '%algolia%'
      AND pg_get_constraintdef(oid) NOT LIKE '%algolia_app_id%';

    IF source_provider_constraint IS NOT NULL THEN
        EXECUTE format(
            'ALTER TABLE algolia_import_jobs DROP CONSTRAINT %I',
            source_provider_constraint
        );
    END IF;
END;
$$;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_source_provider_check
    CHECK (source_provider IN ('algolia', 'meilisearch', 'typesense'));
