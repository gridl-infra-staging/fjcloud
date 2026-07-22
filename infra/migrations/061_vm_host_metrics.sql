-- Host-level telemetry samples keyed to the canonical VM inventory.

CREATE TABLE vm_host_metrics (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vm_id            UUID NOT NULL REFERENCES vm_inventory(id),
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    cpu_pct          DOUBLE PRECISION NOT NULL,
    mem_used_bytes   BIGINT NOT NULL,
    mem_total_bytes  BIGINT NOT NULL,
    disk_used_bytes  BIGINT,
    disk_total_bytes BIGINT,
    net_rx_bytes     BIGINT NOT NULL,
    net_tx_bytes     BIGINT NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_vm_host_metrics_vm_collected_at
    ON vm_host_metrics (vm_id, collected_at DESC);
