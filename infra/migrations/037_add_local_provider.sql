-- Add 'local' to provider CHECK constraints for local development bypass support.

-- customer_deployments: drop and recreate vm_provider CHECK
ALTER TABLE customer_deployments DROP CONSTRAINT IF EXISTS customer_deployments_vm_provider_check;
ALTER TABLE customer_deployments ADD CONSTRAINT customer_deployments_vm_provider_check
    CHECK (vm_provider IN ('aws', 'hetzner', 'gcp', 'oci', 'bare_metal', 'local'));

-- vm_inventory: drop and recreate provider CHECK
ALTER TABLE vm_inventory DROP CONSTRAINT IF EXISTS vm_inventory_provider_check;
ALTER TABLE vm_inventory ADD CONSTRAINT vm_inventory_provider_check
    CHECK (provider IN ('aws', 'hetzner', 'gcp', 'oci', 'bare_metal', 'local'));
