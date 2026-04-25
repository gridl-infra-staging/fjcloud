import type { AybInstance } from '../../src/lib/api/types';
import { quoteSqlLiteral, runSqlWithPsqlFallback } from './postgres_psql_helper';

const SEEDED_INSTANCE_STATUS = 'ready';
const SEEDED_INSTANCE_PLAN = 'starter';

type DatabaseSeedIdentity = {
	customerId: string;
	aybTenantId: string;
	aybSlug: string;
};

export type SeededDatabaseRouteState = DatabaseSeedIdentity & {
	instance: AybInstance;
};

function requireDatabaseUrl(): string {
	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		throw new Error(
			'DATABASE_URL must be set for database route fixture seeding so persisted AYB instance state can be arranged deterministically.'
		);
	}
	return databaseUrl;
}

function buildDeterministicSeedIdentity(customerId: string): DatabaseSeedIdentity {
	const customerKey = customerId.replace(/-/g, '').toLowerCase().slice(0, 12);
	const seedSuffix = customerKey.padEnd(12, '0');
	return {
		customerId,
		aybTenantId: `e2e-tenant-${seedSuffix}`,
		aybSlug: `e2e-db-${seedSuffix}`
	};
}

function parseSeededInstanceRow(output: string): AybInstance {
	const lines = output
		.split('\n')
		.map((line) => line.trim())
		.filter(Boolean);
	const seededRow = lines[lines.length - 1];
	if (!seededRow) {
		throw new Error(`database route fixture seed returned no rows. Output: ${output}`);
	}

	const [id, ayb_slug, ayb_cluster_id, ayb_url, status, plan, created_at, updated_at] =
		seededRow.split('|');
	if (!id || !ayb_slug || !ayb_cluster_id || !ayb_url || !status || !plan || !created_at || !updated_at) {
		throw new Error(
			`database route fixture seed returned malformed row. Output: ${output}`
		);
	}

	return {
		id,
		ayb_slug,
		ayb_cluster_id,
		ayb_url,
		status,
		plan: plan as AybInstance['plan'],
		created_at,
		updated_at
	};
}

export function seedDatabaseRoutePersistedInstance(customerId: string): SeededDatabaseRouteState {
	const seedIdentity = buildDeterministicSeedIdentity(customerId);
	const databaseUrl = requireDatabaseUrl();
	const aybClusterId = `e2e-cluster-${seedIdentity.aybSlug.replace(/^e2e-db-/, '')}`;
	const aybUrl = `https://${seedIdentity.aybSlug}.database.e2e.local`;

	const sql = [
		'WITH removed_fixture_rows AS (',
		'  DELETE FROM ayb_tenants',
		`  WHERE customer_id = ${quoteSqlLiteral(seedIdentity.customerId)}::uuid`,
		`    AND ayb_tenant_id = ${quoteSqlLiteral(seedIdentity.aybTenantId)}`,
		`    AND ayb_slug = ${quoteSqlLiteral(seedIdentity.aybSlug)}`,
		'),',
		'inserted AS (',
		'  INSERT INTO ayb_tenants (',
		'    customer_id,',
		'    ayb_tenant_id,',
		'    ayb_slug,',
		'    ayb_cluster_id,',
		'    ayb_url,',
		'    status,',
		'    plan',
		'  ) VALUES (',
		`    ${quoteSqlLiteral(seedIdentity.customerId)}::uuid,`,
		`    ${quoteSqlLiteral(seedIdentity.aybTenantId)},`,
		`    ${quoteSqlLiteral(seedIdentity.aybSlug)},`,
		`    ${quoteSqlLiteral(aybClusterId)},`,
		`    ${quoteSqlLiteral(aybUrl)},`,
		`    ${quoteSqlLiteral(SEEDED_INSTANCE_STATUS)},`,
		`    ${quoteSqlLiteral(SEEDED_INSTANCE_PLAN)}`,
		'  )',
		'  RETURNING',
		'    id::text,',
		'    ayb_slug,',
		'    ayb_cluster_id,',
		'    ayb_url,',
		'    status,',
		'    plan,',
		'    created_at::text,',
		'    updated_at::text',
		')',
		'SELECT * FROM inserted;'
	].join('\n');

	const output = runSqlWithPsqlFallback(
		databaseUrl,
		sql,
		`database route fixture seed failed for customer ${customerId}`
	);

	return {
		...seedIdentity,
		instance: parseSeededInstanceRow(output)
	};
}

export function cleanupDatabaseRoutePersistedInstance(seed: DatabaseSeedIdentity): void {
	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		return;
	}

	const sql = [
		'DELETE FROM ayb_tenants',
		`WHERE customer_id = ${quoteSqlLiteral(seed.customerId)}::uuid`,
		`  AND ayb_tenant_id = ${quoteSqlLiteral(seed.aybTenantId)}`,
		`  AND ayb_slug = ${quoteSqlLiteral(seed.aybSlug)};`
	].join('\n');

	runSqlWithPsqlFallback(
		databaseUrl,
		sql,
		`database route fixture cleanup failed for customer ${seed.customerId}`
	);
}
