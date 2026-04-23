SELECT COUNT(*) FROM tenants;
SELECT COUNT(*) FROM invoices WHERE created_at > now() - interval '7 days';
SELECT COUNT(*) FROM deployments WHERE status = 'running';
SELECT COUNT(*) FROM usage_records WHERE recorded_at > now() - interval '1 day';
