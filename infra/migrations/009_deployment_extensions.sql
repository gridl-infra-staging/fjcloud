-- Extend customer_deployments for provisioning automation.
-- New columns for cloud provider instance tracking, DNS, and health monitoring.

ALTER TABLE customer_deployments ADD COLUMN provider_vm_id TEXT;
ALTER TABLE customer_deployments ADD COLUMN hostname TEXT;
ALTER TABLE customer_deployments ADD COLUMN flapjack_url TEXT;
ALTER TABLE customer_deployments ADD COLUMN last_health_check_at TIMESTAMPTZ;
ALTER TABLE customer_deployments ADD COLUMN health_status TEXT NOT NULL DEFAULT 'unknown';

-- Add 'failed' to the status check constraint.
ALTER TABLE customer_deployments DROP CONSTRAINT IF EXISTS customer_deployments_status_check;
ALTER TABLE customer_deployments ADD CONSTRAINT customer_deployments_status_check
    CHECK (status IN ('provisioning', 'running', 'stopped', 'terminated', 'failed'));

-- Partial index for health monitor queries (only active deployments).
CREATE INDEX idx_deployments_active ON customer_deployments(status)
    WHERE status != 'terminated';
