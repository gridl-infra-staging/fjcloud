import { requireNonEmptyString } from './contract-guards';

type DashboardUsageCustomer = { customerId: string; token: string };
type ApiCallFn = (
	method: string,
	path: string,
	body?: unknown,
	tokenOverride?: string
) => Promise<Response>;
type CleanupFn = () => Promise<void>;

type DashboardUsageEntry = {
	date: string;
	region: string;
	search_requests: number;
	write_operations: number;
	storage_bytes_avg: number;
	documents_count_avg: number;
};

export type DashboardUsageSeedResult = { month: string };
export type SeedDashboardUsageFn = (seedId: string) => Promise<DashboardUsageSeedResult>;

export type DashboardUsageSeedDependencies = {
	adminApiCall: ApiCallFn;
	apiCall: ApiCallFn;
	arrangeCustomerSession: (seedId: string) => Promise<DashboardUsageCustomer>;
	currentBillingMonth: () => string;
	registerCleanup?: (cleanup: CleanupFn) => void;
};

function daysInBillingMonth(month: string): number {
	const match = /^(\d{4})-(\d{2})$/.exec(month);
	if (!match) {
		throw new Error(`seedDashboardUsage requires YYYY-MM billing month, received ${month}`);
	}
	const year = Number(match[1]);
	const monthNumber = Number(match[2]);
	if (monthNumber < 1 || monthNumber > 12) {
		throw new Error(`seedDashboardUsage requires YYYY-MM billing month, received ${month}`);
	}
	return new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
}

function buildDashboardUsageEntries(month: string, region: string): DashboardUsageEntry[] {
	return Array.from({ length: daysInBillingMonth(month) }, (_, index) => {
		const day = index + 1;
		return {
			date: `${month}-${String(day).padStart(2, '0')}`,
			region,
			search_requests: 1000 + day * 37,
			write_operations: 100 + day * 11,
			storage_bytes_avg: 2_147_483_648,
			documents_count_avg: 50_000
		};
	});
}

async function requireSuccessfulResponse(response: Response, context: string): Promise<void> {
	if (response.ok) {
		return;
	}
	throw new Error(`${context} failed: ${response.status} ${await response.text()}`);
}

async function assertSeedResponse(response: Response, expectedRows: number): Promise<void> {
	await requireSuccessfulResponse(response, 'seedDashboardUsage API arrange');
	const payload = (await response.json()) as { seeded_rows?: unknown };
	if (payload.seeded_rows === expectedRows) {
		return;
	}
	throw new Error(
		`seedDashboardUsage expected ${expectedRows} seeded rows, received ${String(payload.seeded_rows)}`
	);
}

async function assertUsageReady(
	response: Response,
	region: string,
	expectedEntries: DashboardUsageEntry[]
): Promise<void> {
	await requireSuccessfulResponse(response, 'seedDashboardUsage readiness check');
	const payload = (await response.json()) as DashboardUsageEntry[];
	const actualEntries = payload.filter((entry) => entry.region === region);
	if (
		actualEntries.length === expectedEntries.length &&
		actualEntries.every((entry, index) => {
			const expected = expectedEntries[index];
			return (
				entry.date === expected.date &&
				entry.search_requests === expected.search_requests &&
				entry.write_operations === expected.write_operations
			);
		})
	) {
		return;
	}
	throw new Error(
		`seedDashboardUsage readiness expected ${expectedEntries.length} verified rows, received ${actualEntries.length}`
	);
}

function throwWithCleanupFailure(seedError: unknown, cleanupError: unknown): never {
	throw new AggregateError(
		[seedError, cleanupError],
		'seedDashboardUsage cleanup failed after setup failure'
	);
}

export function createDashboardUsageSeedFactory({
	adminApiCall,
	apiCall,
	arrangeCustomerSession,
	currentBillingMonth,
	registerCleanup = () => {}
}: DashboardUsageSeedDependencies): SeedDashboardUsageFn {
	return async (seedId) => {
		const safeSeedId = requireNonEmptyString(seedId, 'seedDashboardUsage requires a seed id');
		const customer = await arrangeCustomerSession(safeSeedId);
		const customerId = requireNonEmptyString(
			customer.customerId,
			'seedDashboardUsage requires the arranged customer id'
		);
		const customerToken = requireNonEmptyString(
			customer.token,
			'seedDashboardUsage requires the arranged customer token'
		);
		const month = currentBillingMonth();
		const region = `e2e-dashboard-usage-${safeSeedId}`;
		const entries = buildDashboardUsageEntries(month, region);
		const usagePath = `/admin/tenants/${encodeURIComponent(customerId)}/usage`;
		const cleanup = async () => {
			const response = await adminApiCall('DELETE', usagePath, { month, region });
			await requireSuccessfulResponse(response, `cleanup seedDashboardUsage for ${safeSeedId}`);
		};

		try {
			await assertSeedResponse(await adminApiCall('POST', usagePath, { entries }), entries.length);
			await assertUsageReady(
				await apiCall(
					'GET',
					`/usage/daily?month=${encodeURIComponent(month)}`,
					undefined,
					customerToken
				),
				region,
				entries
			);
		} catch (error) {
			try {
				await cleanup();
			} catch (cleanupError) {
				throwWithCleanupFailure(error, cleanupError);
			}
			throw error;
		}

		registerCleanup(cleanup);
		return { month };
	};
}
