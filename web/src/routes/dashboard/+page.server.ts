import type { PageServerLoad } from './$types';
import type {
	UsageSummaryResponse,
	DailyUsageEntry,
	EstimatedBillResponse,
	Index
} from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import {
	fallbackDashboardPlanContext,
	type DashboardPlanContext
} from './plan-context';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';

const emptyUsage: UsageSummaryResponse = {
	month: '',
	total_search_requests: 0,
	total_write_operations: 0,
	avg_storage_gb: 0,
	avg_document_count: 0,
	by_region: []
};

type FreeTierProgress = {
	searches: { used: number; limit: number };
	records: { used: number; limit: number };
	storage_gb: { used: number; limit: number };
	indexes: { used: number; limit: number };
};

function deriveFreeTierProgress(
	planContext: DashboardPlanContext,
	usage: UsageSummaryResponse,
	indexes: Index[]
): FreeTierProgress | null {
	if (planContext.billing_plan !== 'free' || !planContext.free_tier_limits) {
		return null;
	}

	return {
		searches: {
			used: usage.total_search_requests,
			limit: planContext.free_tier_limits.max_searches_per_month
		},
		records: {
			used: usage.avg_document_count,
			limit: planContext.free_tier_limits.max_records
		},
		storage_gb: {
			used: usage.avg_storage_gb,
			limit: planContext.free_tier_limits.max_storage_gb
		},
		indexes: {
			used: indexes.length,
			limit: planContext.free_tier_limits.max_indexes
		}
	};
}

export const load: PageServerLoad = async ({ locals, url, parent }) => {
	const api = createApiClient(locals.user?.token);
	const month = url.searchParams.get('month') ?? undefined;
	const parentData = await parent();
	const planContext = parentData.planContext ?? fallbackDashboardPlanContext;

	try {
		const [usage, dailyUsage, indexes] = await Promise.all([
			api.getUsage(month),
			api.getUsageDaily(month),
			retryTransientDashboardApiRequest(() => api.getIndexes()).catch(() => [] as Index[])
		]);

		// Estimate is best-effort — don't fail the page if it errors
		let estimate: EstimatedBillResponse | null = null;
		try {
			estimate = await api.getEstimatedBill(month);
		} catch {
			// No rate card or other issue — show page without estimate
		}

		return {
			usage,
			dailyUsage,
			month: usage.month,
			estimate,
			indexes,
			freeTierProgress: deriveFreeTierProgress(planContext, usage, indexes)
		};
	} catch {
		const fallbackMonth = month ?? new Date().toISOString().slice(0, 7);
		return {
			usage: { ...emptyUsage, month: fallbackMonth },
			dailyUsage: [] as DailyUsageEntry[],
			month: fallbackMonth,
			estimate: null,
			indexes: [] as Index[],
			freeTierProgress: null
		};
	}
};
