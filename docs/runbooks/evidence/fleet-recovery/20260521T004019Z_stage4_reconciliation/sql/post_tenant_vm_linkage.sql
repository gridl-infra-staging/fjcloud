COPY (
  SELECT
    ct.customer_id::text,
    ct.tenant_id,
    ct.deployment_id::text,
    ct.vm_id::text,
    cd.status,
    cd.hostname,
    cd.flapjack_url,
    vi.hostname AS vm_hostname,
    vi.flapjack_url AS vm_flapjack_url
  FROM customer_tenants ct
  JOIN customer_deployments cd ON cd.id = ct.deployment_id
  LEFT JOIN vm_inventory vi ON vi.id = ct.vm_id
  WHERE cd.status != 'terminated'
    AND cd.vm_provider = 'aws'
  ORDER BY cd.created_at DESC
  LIMIT 400
) TO STDOUT WITH CSV HEADER;
