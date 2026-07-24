-- Append-only VM autorepair lifecycle history keyed to canonical VM inventory.

CREATE TABLE vm_lifecycle_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vm_id       UUID NOT NULL REFERENCES vm_inventory(id),
    event_type  TEXT NOT NULL CHECK (event_type IN (
        'detected_dead',
        'replacement_provisioning',
        'replacement_booted',
        'tenants_replaced',
        'replacement_completed',
        'replacement_failed',
        'replacement_refused'
    )),
    detail      JSONB NOT NULL CHECK (jsonb_typeof(detail) = 'object'),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        event_type <> 'replacement_refused'
        OR (
            jsonb_typeof(detail -> 'guardrail') = 'string'
            AND btrim(detail ->> 'guardrail') <> ''
        )
    )
);

CREATE INDEX idx_vm_lifecycle_events_vm_created_id
    ON vm_lifecycle_events (vm_id, created_at, id);

CREATE FUNCTION reject_vm_lifecycle_events_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'vm_lifecycle_events is append-only'
        USING ERRCODE = '25006';
END;
$$;

CREATE TRIGGER trg_vm_lifecycle_events_append_only
BEFORE UPDATE OR DELETE ON vm_lifecycle_events
FOR EACH ROW
EXECUTE FUNCTION reject_vm_lifecycle_events_mutation();
