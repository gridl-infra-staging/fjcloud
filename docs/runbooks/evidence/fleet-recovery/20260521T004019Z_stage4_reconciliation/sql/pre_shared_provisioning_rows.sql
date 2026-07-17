COPY (
  SELECT
    cd.id::text AS deployment_id,
    cd.customer_id::text AS customer_id,
    cd.status,
    cd.vm_provider,
    cd.provider_vm_id,
    cd.hostname,
    cd.flapjack_url,
    cd.created_at,
    ct.tenant_id,
    ct.vm_id::text AS tenant_vm_id,
    vi.id::text AS inventory_vm_id
  FROM customer_deployments cd
  LEFT JOIN customer_tenants ct ON ct.deployment_id = cd.id
  LEFT JOIN vm_inventory vi ON vi.id::text = cd.provider_vm_id
  WHERE cd.status = 'provisioning'
    AND cd.vm_provider = 'aws'
    AND cd.provider_vm_id = vi.id::text
    AND cd.hostname IS NOT NULL
    AND cd.flapjack_url IS NOT NULL
  ORDER BY cd.created_at
) TO STDOUT WITH CSV HEADER;
