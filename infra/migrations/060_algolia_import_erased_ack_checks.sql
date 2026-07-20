DO $$
DECLARE
    not_applicable_constraint TEXT;
    seal_acknowledged_constraint TEXT;
    terminal_ack_constraint TEXT;
BEGIN
    SELECT conname INTO not_applicable_constraint
    FROM pg_constraint
    WHERE conrelid = 'algolia_import_jobs'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%engine_ack_state <> ''not_applicable''%'
      AND pg_get_constraintdef(oid) NOT LIKE '%erased_at IS NOT NULL%';

    SELECT conname INTO seal_acknowledged_constraint
    FROM pg_constraint
    WHERE conrelid = 'algolia_import_jobs'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%engine_ack_state <> ''seal_acknowledged''%'
      AND pg_get_constraintdef(oid) NOT LIKE '%erased_at IS NOT NULL%';

    SELECT conname INTO terminal_ack_constraint
    FROM pg_constraint
    WHERE conrelid = 'algolia_import_jobs'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%engine_ack_state <> ALL%'
      AND pg_get_constraintdef(oid) LIKE '%outbox_pending%'
      AND pg_get_constraintdef(oid) LIKE '%acknowledged%'
      AND pg_get_constraintdef(oid) NOT LIKE '%erased_at IS NOT NULL%';

    IF not_applicable_constraint IS NOT NULL THEN
        EXECUTE format('ALTER TABLE algolia_import_jobs DROP CONSTRAINT %I', not_applicable_constraint);
    END IF;
    IF seal_acknowledged_constraint IS NOT NULL THEN
        EXECUTE format('ALTER TABLE algolia_import_jobs DROP CONSTRAINT %I', seal_acknowledged_constraint);
    END IF;
    IF terminal_ack_constraint IS NOT NULL THEN
        EXECUTE format('ALTER TABLE algolia_import_jobs DROP CONSTRAINT %I', terminal_ack_constraint);
    END IF;
END;
$$;

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_ack_not_applicable_terminal_or_erased
    CHECK (engine_ack_state <> 'not_applicable' OR erased_at IS NOT NULL OR (
        status = 'failed'
        AND publication_disposition = 'not_started'
        AND dispatch_intent_state = 'absent'
        AND engine_job_id IS NULL
        AND error_code IS NOT NULL
        AND retryable = FALSE
    ));

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_seal_acknowledged_interrupted_or_erased
    CHECK (engine_ack_state <> 'seal_acknowledged' OR erased_at IS NOT NULL OR (
        status = 'interrupted'
        AND publication_disposition = 'not_started'
        AND dispatch_intent_state <> 'absent'
        AND engine_job_id IS NULL
    ));

ALTER TABLE algolia_import_jobs
    ADD CONSTRAINT algolia_import_jobs_terminal_ack_state_terminal_or_erased
    CHECK (engine_ack_state NOT IN ('outbox_pending', 'acknowledged') OR erased_at IS NOT NULL OR (
        status IN ('cancelled', 'completed', 'completed_with_warnings', 'failed', 'interrupted')
        AND dispatch_intent_state <> 'absent'
        AND engine_job_id IS NOT NULL
    ));
