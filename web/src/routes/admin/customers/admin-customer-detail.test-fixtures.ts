/**
 * Shared fixtures for admin customer detail component tests.
 *
 * Keep the canonical tab-content fixture data in one module so extracted tests
 * cannot drift when the detail surface changes.
 */
import type { AdminAuditRow, AdminTenantDetail } from '$lib/admin-client';

export const POPULATED_AUDIT_FIXTURE_ROWS: AdminAuditRow[] = [
	{
		id: 'eeeeeeee-0001-0000-0000-000000000001',
		actor_id: '00000000-0000-0000-0000-000000000000',
		action: 'customer_suspended',
		target_tenant_id: 'aaaaaaaa-0002-0000-0000-000000000002',
		metadata: { reason: 'billing_review' },
		created_at: '2026-04-01T11:30:00Z'
	},
	{
		id: 'eeeeeeee-0002-0000-0000-000000000002',
		actor_id: '00000000-0000-0000-0000-000000000000',
		action: 'quotas_updated',
		target_tenant_id: 'aaaaaaaa-0002-0000-0000-000000000002',
		metadata: { max_query_rps: 120 },
		created_at: '2026-03-30T12:00:00Z'
	}
];

export const EMPTY_AUDIT_FIXTURE_ROWS: AdminAuditRow[] = [];

const DETAIL_TENANT_FIXTURE = {
	id: 'aaaaaaaa-0002-0000-0000-000000000002',
	name: 'Beta Labs',
	email: 'billing@beta.dev',
	status: 'suspended',
	billing_plan: 'starter',
	last_accessed_at: '2026-04-18T09:00:00Z',
	subscription_status: 'past_due',
	overdue_invoice_count: 1,
	billing_health: 'yellow',
	created_at: '2026-02-11T12:00:00Z',
	updated_at: '2026-04-18T09:00:00Z',
	stripe_customer_id: 'cus_123'
} satisfies AdminTenantDetail;

export const DETAIL_FIXTURE = {
	tenant: DETAIL_TENANT_FIXTURE,
	indexes: [
		{ name: 'products', region: 'us-east-1', status: 'ready', entries: 1200, tier: 'active' },
		{ name: 'orders', region: 'eu-west-1', status: 'ready', entries: 320, tier: 'cold' }
	],
	deployments: [
		{
			id: 'bbbbbbbb-0001-0000-0000-000000000001',
			customer_id: 'aaaaaaaa-0002-0000-0000-000000000002',
			region: 'us-east-1',
			vm_provider: 'aws',
			status: 'running',
			health_status: 'healthy',
			flapjack_url: 'https://node1.flapjack.foo',
			created_at: '2026-02-13T12:00:00Z',
			last_health_check_at: '2026-02-22T10:00:00Z'
		}
	],
	usage: {
		month: '2026-02',
		total_search_requests: 120000,
		total_write_operations: 25000,
		avg_storage_gb: 42.5,
		avg_document_count: 92000,
		by_region: []
	},
	invoices: [
		{
			id: 'cccccccc-0001-0000-0000-000000000001',
			period_start: '2026-01-01',
			period_end: '2026-01-31',
			subtotal_cents: 12000,
			total_cents: 12000,
			status: 'paid',
			minimum_applied: false,
			created_at: '2026-02-01T00:00:00Z'
		},
		{
			id: 'cccccccc-0002-0000-0000-000000000002',
			period_start: '2026-02-01',
			period_end: '2026-02-28',
			subtotal_cents: 18000,
			total_cents: 18000,
			status: 'failed',
			minimum_applied: false,
			created_at: '2026-03-01T00:00:00Z'
		},
		{
			id: 'cccccccc-0003-0000-0000-000000000003',
			period_start: '2026-03-01',
			period_end: '2026-03-31',
			subtotal_cents: 9000,
			total_cents: 9000,
			status: 'draft',
			minimum_applied: false,
			created_at: '2026-04-01T00:00:00Z'
		}
	],
	rateCard: {
		id: 'dddddddd-0001-0000-0000-000000000001',
		name: 'Default',
		storage_rate_per_mb_month: '0.05',
		cold_storage_rate_per_gb_month: '0.10',
		object_storage_rate_per_gb_month: '0.02',
		object_storage_egress_rate_per_gb: '0.01',
		minimum_spend_cents: 1000,
		shared_minimum_spend_cents: 500,
		has_override: false,
		override_fields: {},
		region_multipliers: {}
	},
	quotas: {
		defaults: {
			max_query_rps: 100,
			max_write_rps: 50,
			max_storage_bytes: 10_737_418_240,
			max_indexes: 10
		},
		indexes: [
			{
				index_name: 'products',
				effective: {
					max_query_rps: 100,
					max_write_rps: 50,
					max_storage_bytes: 10_737_418_240,
					max_indexes: 10
				},
				override: {}
			},
			{
				index_name: 'orders',
				effective: {
					max_query_rps: 120,
					max_write_rps: 60,
					max_storage_bytes: 2_147_483_648,
					max_indexes: 10
				},
				override: {
					max_query_rps: 120,
					max_write_rps: 60,
					max_storage_bytes: 2_147_483_648
				}
			}
		]
	},
	audit: POPULATED_AUDIT_FIXTURE_ROWS
};

export const ACTIVE_DETAIL_FIXTURE = {
	...DETAIL_FIXTURE,
	tenant: {
		...DETAIL_FIXTURE.tenant,
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		name: 'Acme Corp',
		email: 'ops@acme.dev',
		status: 'active'
	}
};
