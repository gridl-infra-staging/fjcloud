// Analytics API types (top searches, counts, no-result rate, conversions, etc.).

export interface AnalyticsTopSearch {
	search: string;
	count: number;
	nbHits: number;
}

export interface AnalyticsTopSearchesResponse {
	searches: AnalyticsTopSearch[];
}

export interface AnalyticsDateCount {
	date: string;
	count: number;
}

export interface AnalyticsSearchCountResponse {
	count: number;
	dates: AnalyticsDateCount[];
}

export interface AnalyticsNoResultRateDateEntry {
	date: string;
	rate: number | null;
	count: number;
	noResults: number;
}

export interface AnalyticsNoResultRateResponse {
	rate: number | null;
	count: number;
	noResults: number;
	dates: AnalyticsNoResultRateDateEntry[];
}

export interface AnalyticsRequiredDateRangeParams {
	startDate: string;
	endDate: string;
	country?: string;
}

export interface AnalyticsDateRangeParams {
	startDate?: string;
	endDate?: string;
	limit?: number;
	country?: string;
}

export interface AnalyticsStatusResponse {
	indexName: string;
	enabled: boolean;
}

export interface AnalyticsCountByKey {
	[key: string]: number;
}

export interface AnalyticsDevices {
	desktop?: number;
	mobile?: number;
	tablet?: number;
}

export interface AnalyticsDevicesResponse {
	devices: AnalyticsDevices;
}

export interface AnalyticsCountriesResponse {
	countries: AnalyticsCountByKey;
}

export interface AnalyticsFilterValuesResponse {
	filters: Record<string, AnalyticsCountByKey>;
}

export interface AnalyticsConversionMetrics {
	ctr?: number;
	addToCart?: number;
	purchase?: number;
	conversionRate?: number;
}

export interface AnalyticsConversionTrendPoint {
	date: string;
	conversionRate: number;
}

export interface AnalyticsConversionRateResponse {
	conversions: AnalyticsConversionMetrics;
	previousConversions?: AnalyticsConversionMetrics;
	trend?: AnalyticsConversionTrendPoint[];
	countries?: string[];
	country?: string | null;
}

export interface AnalyticsConversionKpiDelta {
	current: number;
	previous: number;
	delta: number;
}

export interface AnalyticsConversionSubtabPayload {
	country: string | null;
	countries: string[];
	trend: AnalyticsConversionTrendPoint[];
	kpis: {
		ctr: AnalyticsConversionKpiDelta;
		addToCart: AnalyticsConversionKpiDelta;
		purchase: AnalyticsConversionKpiDelta;
		conversionRate: AnalyticsConversionKpiDelta;
	};
}
