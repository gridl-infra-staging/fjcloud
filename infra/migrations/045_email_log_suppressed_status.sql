ALTER TABLE email_log
    DROP CONSTRAINT IF EXISTS email_log_delivery_status_check;

ALTER TABLE email_log
    ADD CONSTRAINT email_log_delivery_status_check
    CHECK (delivery_status IN ('success', 'failed', 'suppressed'));
