COPY (
  SELECT id::text, status, region, provider, hostname, flapjack_url, created_at, updated_at
  FROM vm_inventory
  WHERE hostname IN (
    'vm-shared-3bd2b971.flapjack.foo',
    'vm-shared-391f314f.flapjack.foo',
    'vm-shared-480b5169.flapjack.foo',
    'vm-20aa6d79.flapjack.foo'
  )
  ORDER BY hostname
) TO STDOUT WITH CSV HEADER;
