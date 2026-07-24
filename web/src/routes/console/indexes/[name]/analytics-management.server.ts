import { fail } from '@sveltejs/kit';
import type { ApiClient } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import type {
	AnalyticsDateRangeParams,
	AnalyticsConversionSubtabPayload,
	AnalyticsConversionKpiDelta,
	AnalyticsConversionMetrics,
	AnalyticsConversionTrendPoint,
	AnalyticsRequiredDateRangeParams,
	AnalyticsSearchCountResponse,
	AnalyticsNoResultRateResponse,
	AnalyticsTopSearchesResponse,
	AnalyticsStatusResponse,
	AnalyticsConversionRateResponse
} from '$lib/api/types';
import { errorMessage } from './document-management.server';

const PERIOD_TO_DAYS: Record<AnalyticsPeriod, number> = {
	'7d': 7,
	'30d': 30,
	'90d': 90
};

export type AnalyticsPeriod = '7d' | '30d' | '90d';

export type AnalyticsSummaryPayload = {
	analyticsPeriod: AnalyticsPeriod;
	analyticsStartDate: string;
	analyticsEndDate: string;
	searchCount: AnalyticsSearchCountResponse | null;
	noResultRate: AnalyticsNoResultRateResponse | null;
	topSearches: AnalyticsTopSearchesResponse | null;
	noResults: AnalyticsTopSearchesResponse | null;
	analyticsStatus: AnalyticsStatusResponse | null;
};

type AnalyticsActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

type AnalyticsDateRangeErrorKey =
	| 'analyticsDevicesError'
	| 'analyticsCountriesError'
	| 'analyticsFiltersError';

type AnalyticsDateRangeResponseKey = 'analyticsDevices' | 'analyticsCountries' | 'analyticsFilters';

function toIsoDateUtc(date: Date): string {
	return date.toISOString().slice(0, 10);
}

export function resolveAnalyticsPeriod(rawPeriod: string | null): AnalyticsPeriod {
	if (rawPeriod === '30d' || rawPeriod === '90d') return rawPeriod;
	return '7d';
}

// Returns a fully-populated date window (both bounds always present), so the
// return type is the required-fields variant — callers can assign the dates to
// non-optional fields (e.g. AnalyticsSummaryPayload.analyticsStartDate) without
// a `string | undefined` narrowing step.
export function analyticsDateRange(period: AnalyticsPeriod): AnalyticsRequiredDateRangeParams {
	const days = PERIOD_TO_DAYS[period];
	const now = new Date();
	const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
	const start = new Date(end);
	start.setUTCDate(end.getUTCDate() - (days - 1));

	return {
		startDate: toIsoDateUtc(start),
		endDate: toIsoDateUtc(end)
	};
}

export async function loadAnalyticsPayload(
	api: ApiClient,
	indexName: string,
	rawPeriod: string | null
): Promise<AnalyticsSummaryPayload> {
	const analyticsPeriod = resolveAnalyticsPeriod(rawPeriod);
	// `period` is the single owner of the analytics date window. The canonical
	// start/end dates are derived here and surfaced in the payload so subtabs
	// (e.g. DevicesSubtab) can echo them back in their fetch actions without
	// reimplementing period-to-date math. Do not accept URL startDate/endDate
	// overrides here — that created a second owner that silently pinned the
	// window when the period selector was clicked.
	const analyticsParams = analyticsDateRange(analyticsPeriod);
	const analyticsTopParams: AnalyticsDateRangeParams = { ...analyticsParams, limit: 10 };

	const [searchCount, noResultRate, topSearches, noResults, analyticsStatus] = await Promise.all([
		api.getAnalyticsSearchCount(indexName, analyticsParams).catch(() => null),
		api.getAnalyticsNoResultRate(indexName, analyticsParams).catch(() => null),
		api.getAnalyticsTopSearches(indexName, analyticsTopParams).catch(() => null),
		api.getAnalyticsNoResults(indexName, analyticsTopParams).catch(() => null),
		api.getAnalyticsStatus(indexName).catch(() => null)
	]);

	return {
		analyticsPeriod,
		analyticsStartDate: analyticsParams.startDate,
		analyticsEndDate: analyticsParams.endDate,
		searchCount,
		noResultRate,
		topSearches,
		noResults,
		analyticsStatus
	};
}

function requiredDateRange(data: FormData) {
	const startDate = (data.get('startDate') as string | null)?.trim() ?? '';
	const endDate = (data.get('endDate') as string | null)?.trim() ?? '';
	if (!startDate || !endDate) {
		throw new Error('startDate and endDate are required');
	}
	return { startDate, endDate } as AnalyticsRequiredDateRangeParams;
}

type ConversionMetricKey = 'ctr' | 'addToCart' | 'purchase' | 'conversionRate';

function parseOptionalCountry(data: FormData): string | undefined {
	const rawCountry = (data.get('country') as string | null)?.trim() ?? '';
	return rawCountry || undefined;
}

function parseUtcDate(rawDate: string): Date | null {
	const parsed = new Date(`${rawDate}T00:00:00.000Z`);
	if (Number.isNaN(parsed.getTime())) return null;
	return parsed;
}

function formatUtcDate(date: Date): string {
	return date.toISOString().slice(0, 10);
}

function previousDateRange(
	params: AnalyticsRequiredDateRangeParams
): AnalyticsRequiredDateRangeParams | null {
	const startDate = parseUtcDate(params.startDate);
	const endDate = parseUtcDate(params.endDate);
	if (!startDate || !endDate) return null;
	const daySpanMs = endDate.getTime() - startDate.getTime();
	if (daySpanMs < 0) return null;

	const previousEndDate = new Date(startDate);
	previousEndDate.setUTCDate(previousEndDate.getUTCDate() - 1);
	const previousStartDate = new Date(previousEndDate.getTime() - daySpanMs);
	return {
		startDate: formatUtcDate(previousStartDate),
		endDate: formatUtcDate(previousEndDate)
	};
}

type FetchAnalyticsByDateRangeArgs<
	T,
	TResponseKey extends AnalyticsDateRangeResponseKey,
	TErrorKey extends AnalyticsDateRangeErrorKey
> = AnalyticsActionArgs & {
	errorKey: TErrorKey;
	responseKey: TResponseKey;
	invalidDateRangeMessage: string;
	loadErrorMessage: string;
	load: (api: ApiClient, indexName: string, params: AnalyticsRequiredDateRangeParams) => Promise<T>;
};

async function fetchAnalyticsByDateRange<
	T,
	TResponseKey extends AnalyticsDateRangeResponseKey,
	TErrorKey extends AnalyticsDateRangeErrorKey
>({
	request,
	indexName,
	token,
	errorKey,
	responseKey,
	invalidDateRangeMessage,
	loadErrorMessage,
	load
}: FetchAnalyticsByDateRangeArgs<T, TResponseKey, TErrorKey>) {
	let params: AnalyticsRequiredDateRangeParams;
	try {
		params = requiredDateRange(await request.formData());
	} catch (err) {
		return fail(400, { [errorKey]: errorMessage(err, invalidDateRangeMessage) } as Record<
			TErrorKey,
			string
		>);
	}

	const api = createApiClient(token);
	try {
		const payload = await load(api, indexName, params);
		return { [responseKey]: payload } as Record<TResponseKey, T>;
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return fail(400, { [errorKey]: errorMessage(err, loadErrorMessage) } as Record<
			TErrorKey,
			string
		>);
	}
}

function readConversionMetric(
	metrics: AnalyticsConversionMetrics | null | undefined,
	key: ConversionMetricKey
): number {
	const value = metrics?.[key];
	return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function conversionKpiDelta(
	currentMetrics: AnalyticsConversionMetrics,
	previousMetrics: AnalyticsConversionMetrics | null | undefined,
	key: ConversionMetricKey
): AnalyticsConversionKpiDelta {
	const current = readConversionMetric(currentMetrics, key);
	const previous = readConversionMetric(previousMetrics, key);
	const delta = Number((current - previous).toFixed(6));
	return {
		current,
		previous,
		delta
	};
}

function normalizeTrendPoints(
	points: AnalyticsConversionTrendPoint[] | undefined
): AnalyticsConversionTrendPoint[] {
	if (!Array.isArray(points)) return [];
	return points
		.filter((point) => point && typeof point.date === 'string')
		.map((point) => ({
			date: point.date,
			conversionRate:
				typeof point.conversionRate === 'number' && Number.isFinite(point.conversionRate)
					? point.conversionRate
					: 0
		}));
}

function buildConversionSubtabPayload(
	currentPayload: AnalyticsConversionRateResponse,
	previousPayload: AnalyticsConversionRateResponse | null,
	requestedCountry: string | undefined
): AnalyticsConversionSubtabPayload {
	const currentMetrics = currentPayload.conversions ?? {};
	const previousMetrics = currentPayload.previousConversions ?? previousPayload?.conversions;
	const selectedCountry = requestedCountry ?? currentPayload.country ?? null;
	const countries = Array.isArray(currentPayload.countries)
		? currentPayload.countries.filter((country): country is string => typeof country === 'string')
		: [];

	return {
		country: selectedCountry,
		countries,
		trend: normalizeTrendPoints(currentPayload.trend),
		kpis: {
			ctr: conversionKpiDelta(currentMetrics, previousMetrics, 'ctr'),
			addToCart: conversionKpiDelta(currentMetrics, previousMetrics, 'addToCart'),
			purchase: conversionKpiDelta(currentMetrics, previousMetrics, 'purchase'),
			conversionRate: conversionKpiDelta(currentMetrics, previousMetrics, 'conversionRate')
		}
	};
}

export async function fetchAnalyticsDevicesAction({
	request,
	indexName,
	token
}: AnalyticsActionArgs) {
	return fetchAnalyticsByDateRange({
		request,
		indexName,
		token,
		errorKey: 'analyticsDevicesError',
		responseKey: 'analyticsDevices',
		invalidDateRangeMessage: 'Invalid analytics date range',
		loadErrorMessage: 'Failed to fetch analytics devices',
		load: (api, currentIndexName, params) => api.getAnalyticsDevices(currentIndexName, params)
	});
}

export async function fetchAnalyticsCountriesAction({
	request,
	indexName,
	token
}: AnalyticsActionArgs) {
	return fetchAnalyticsByDateRange({
		request,
		indexName,
		token,
		errorKey: 'analyticsCountriesError',
		responseKey: 'analyticsCountries',
		invalidDateRangeMessage: 'Invalid analytics date range',
		loadErrorMessage: 'Failed to fetch analytics countries',
		load: (api, currentIndexName, params) => api.getAnalyticsCountries(currentIndexName, params)
	});
}

export async function fetchAnalyticsFiltersAction({
	request,
	indexName,
	token
}: AnalyticsActionArgs) {
	return fetchAnalyticsByDateRange({
		request,
		indexName,
		token,
		errorKey: 'analyticsFiltersError',
		responseKey: 'analyticsFilters',
		invalidDateRangeMessage: 'Invalid analytics date range',
		loadErrorMessage: 'Failed to fetch analytics filters',
		load: (api, currentIndexName, params) => api.getAnalyticsFilters(currentIndexName, params)
	});
}

export async function fetchAnalyticsConversionRateAction({
	request,
	indexName,
	token
}: AnalyticsActionArgs) {
	let params: AnalyticsRequiredDateRangeParams;
	let country: string | undefined;
	try {
		const data = await request.formData();
		params = requiredDateRange(data);
		country = parseOptionalCountry(data);
	} catch (err) {
		return fail(400, {
			analyticsConversionRateError: errorMessage(err, 'Invalid analytics date range')
		});
	}

	const api = createApiClient(token);
	try {
		const currentParams = country ? { ...params, country } : params;
		const currentAnalyticsConversionRate: AnalyticsConversionRateResponse =
			await api.getAnalyticsConversionRate(indexName, currentParams);

		let previousAnalyticsConversionRate: AnalyticsConversionRateResponse | null = null;
		const previousParams = previousDateRange(params);
		if (!currentAnalyticsConversionRate.previousConversions && previousParams) {
			previousAnalyticsConversionRate = await api.getAnalyticsConversionRate(
				indexName,
				country ? { ...previousParams, country } : previousParams
			);
		}

		const analyticsConversionRate = buildConversionSubtabPayload(
			currentAnalyticsConversionRate,
			previousAnalyticsConversionRate,
			country
		);
		return { analyticsConversionRate };
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return fail(400, {
			analyticsConversionRateError: errorMessage(err, 'Failed to fetch analytics conversion rate')
		});
	}
}
