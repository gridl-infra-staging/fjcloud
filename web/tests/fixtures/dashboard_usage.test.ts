import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import {
	createDashboardUsageSeedFactory,
	type DashboardUsageSeedDependencies
} from './dashboard_usage';
import { __fixtureTestSeams } from './fixtures';

const FRESH_CUSTOMER_ID = '11111111-1111-4111-8111-111111111111';
const FOREIGN_CUSTOMER_ID = '22222222-2222-4222-8222-222222222222';
const FRESH_TOKEN = 'fresh-customer-token';

type UsageRow = {
	customerId: string;
	date: string;
	region: string;
	search_requests: number;
	write_operations: number;
};
type CleanupFn = () => Promise<void>;

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

function createUsageHarness(seededRowsOverride?: number) {
	const usageRows: UsageRow[] = [
		{
			customerId: FOREIGN_CUSTOMER_ID,
			date: '2026-08-01',
			region: 'foreign-current-month-row',
			search_requests: 999_999,
			write_operations: 999_999
		}
	];
	const cleanupTasks: CleanupFn[] = [];
	let trackCustomerForCleanup: (customerId: string) => void = () => {};
	const arrangeCustomerSession = vi.fn(async () => {
		trackCustomerForCleanup(FRESH_CUSTOMER_ID);
		return { customerId: FRESH_CUSTOMER_ID, token: FRESH_TOKEN };
	});
	const adminApiCall = vi.fn(async (method: string, path: string, body?: unknown) => {
		if (method === 'POST' && path === `/admin/tenants/${FRESH_CUSTOMER_ID}/usage`) {
			const entries = (body as { entries: Omit<UsageRow, 'customerId'>[] }).entries;
			usageRows.push(...entries.map((entry) => ({ ...entry, customerId: FRESH_CUSTOMER_ID })));
			return jsonResponse({ seeded_rows: seededRowsOverride ?? entries.length }, 201);
		}
		if (method === 'DELETE' && path === `/admin/tenants/${FRESH_CUSTOMER_ID}/usage`) {
			const target = body as { month: string; region: string };
			for (let index = usageRows.length - 1; index >= 0; index -= 1) {
				const row = usageRows[index];
				if (
					row.customerId === FRESH_CUSTOMER_ID &&
					row.date.startsWith(target.month) &&
					row.region === target.region
				) {
					usageRows.splice(index, 1);
				}
			}
			return new Response(null, { status: 204 });
		}
		return new Response('unexpected admin API request', { status: 500 });
	});
	const apiCall = vi.fn(async (_method: string, path: string, _body?: unknown, token?: string) => {
		if (path !== '/usage/daily?month=2026-08' || token !== FRESH_TOKEN) {
			return new Response('unexpected customer API request', { status: 500 });
		}
		return jsonResponse(
			usageRows
				.filter((row) => row.customerId === FRESH_CUSTOMER_ID && row.date.startsWith('2026-08'))
				.map((row) => {
					const entry: Record<string, unknown> = { ...row };
					delete entry.customerId;
					return entry;
				})
		);
	});
	const deleteTrackedCustomerForCleanup = vi.fn(async () => {});
	const dependencies: DashboardUsageSeedDependencies = {
		adminApiCall,
		apiCall,
		arrangeCustomerSession,
		currentBillingMonth: () => '2026-08',
		registerCleanup: (cleanup) => {
			cleanupTasks.push(cleanup);
		}
	};

	return {
		adminApiCall,
		apiCall,
		arrangeCustomerSession,
		deleteTrackedCustomerForCleanup,
		dependencies,
		runWithFixtureCleanup: async (body: () => Promise<void>) => {
			let bodyFailure: unknown;
			try {
				await __fixtureTestSeams.runTrackedCustomerCleanup(
					async (trackCustomer) => {
						trackCustomerForCleanup = trackCustomer;
						await body();
					},
					{ deleteTrackedCustomerForCleanup }
				);
			} catch (error) {
				bodyFailure = error;
			}
			for (const cleanup of cleanupTasks.splice(0).reverse()) {
				await cleanup();
			}
			if (bodyFailure) {
				throw bodyFailure;
			}
		},
		usageRows
	};
}

describe('dashboard usage fixture', () => {
	it('seeds and verifies one fresh customer through maintained API contracts', async () => {
		const harness = createUsageHarness();
		const seedDashboardUsage = createDashboardUsageSeedFactory(harness.dependencies);

		await harness.runWithFixtureCleanup(async () => {
			await expect(seedDashboardUsage('isolation-proof')).resolves.toEqual({ month: '2026-08' });

			expect(harness.arrangeCustomerSession).toHaveBeenCalledOnce();
			expect(harness.adminApiCall).toHaveBeenCalledWith(
				'POST',
				`/admin/tenants/${FRESH_CUSTOMER_ID}/usage`,
				expect.objectContaining({
					entries: expect.arrayContaining([
						expect.objectContaining({
							date: '2026-08-01',
							region: 'e2e-dashboard-usage-isolation-proof',
							search_requests: 1037,
							write_operations: 111
						})
					])
				})
			);
			expect(harness.apiCall).toHaveBeenCalledWith(
				'GET',
				'/usage/daily?month=2026-08',
				undefined,
				FRESH_TOKEN
			);
			expect(harness.usageRows.filter((row) => row.customerId === FRESH_CUSTOMER_ID)).toHaveLength(
				31
			);
		});

		expect(harness.usageRows).toEqual([
			expect.objectContaining({
				customerId: FOREIGN_CUSTOMER_ID,
				region: 'foreign-current-month-row'
			})
		]);
	});

	it('cleans seeded usage through the API after the test body fails', async () => {
		const harness = createUsageHarness();
		const seedDashboardUsage = createDashboardUsageSeedFactory(harness.dependencies);
		const bodyFailure = new Error('dashboard assertion failed');

		await expect(
			harness.runWithFixtureCleanup(async () => {
				await seedDashboardUsage('body-failure');
				throw bodyFailure;
			})
		).rejects.toBe(bodyFailure);

		expect(harness.deleteTrackedCustomerForCleanup).toHaveBeenCalledWith(FRESH_CUSTOMER_ID);
		expect(harness.adminApiCall).toHaveBeenCalledWith(
			'DELETE',
			`/admin/tenants/${FRESH_CUSTOMER_ID}/usage`,
			{ month: '2026-08', region: 'e2e-dashboard-usage-body-failure' }
		);
		expect(harness.usageRows).toEqual([
			expect.objectContaining({ customerId: FOREIGN_CUSTOMER_ID })
		]);
	});

	it('cleans seeded usage through the API when readiness validation fails', async () => {
		const harness = createUsageHarness(30);
		const seedDashboardUsage = createDashboardUsageSeedFactory(harness.dependencies);

		await expect(
			harness.runWithFixtureCleanup(async () => {
				await seedDashboardUsage('setup-failure');
			})
		).rejects.toThrow('seedDashboardUsage expected 31 seeded rows, received 30');

		expect(harness.deleteTrackedCustomerForCleanup).toHaveBeenCalledWith(FRESH_CUSTOMER_ID);
		expect(harness.adminApiCall).toHaveBeenCalledWith(
			'DELETE',
			`/admin/tenants/${FRESH_CUSTOMER_ID}/usage`,
			{ month: '2026-08', region: 'e2e-dashboard-usage-setup-failure' }
		);
		expect(harness.usageRows).toEqual([
			expect.objectContaining({ customerId: FOREIGN_CUSTOMER_ID })
		]);
	});

	it('contains no raw SQL schema coupling', () => {
		const source = readFileSync(
			path.resolve(process.cwd(), 'tests/fixtures/dashboard_usage.ts'),
			'utf8'
		);

		expect(source).not.toMatch(/\b(?:INSERT\s+INTO|DELETE\s+FROM)\b/i);
		expect(source).not.toContain('postgres_psql_helper');
		expect(source).not.toContain('runSql');
	});
});
