SELECT
  COUNT(*) FILTER (WHERE cd.status = 'provisioning') AS provisioning_total,
  COUNT(*) FILTER (
    WHERE cd.status = 'provisioning'
      AND EXISTS (
        SELECT 1
        FROM vm_inventory vi
        WHERE vi.id::text = cd.provider_vm_id
      )
  ) AS provider_vm_id_matches_vm_inventory_id,
  COUNT(*) FILTER (
    WHERE cd.status = 'provisioning'
      AND cd.provider_vm_id LIKE 'aws:%'
  ) AS provider_vm_id_aws_style
FROM customer_deployments cd;
