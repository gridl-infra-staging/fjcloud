SELECT COUNT(*) AS customers_total FROM customers;
SELECT COUNT(*) AS customer_tenants_total FROM customer_tenants;
SELECT COUNT(*) AS invoices_last_7d FROM invoices WHERE created_at > now() - interval '7 days';
SELECT COUNT(*) AS deployments_running FROM customer_deployments WHERE status = 'running';
SELECT COUNT(*) AS usage_records_last_1d FROM usage_records WHERE recorded_at > now() - interval '1 day';
SELECT COUNT(*) AS migrations_total FROM _sqlx_migrations;
SELECT MAX(version) AS migrations_max_version FROM _sqlx_migrations;
