import { ApiRequestError, type ApiClient } from '$lib/api/client';
import type { IndexMetricsResponse } from '$lib/api/types';

export type MetricsLoadError = {
	code: number;
	message: string;
};

export type MetricsPayload = {
	metrics: IndexMetricsResponse | null;
	error: MetricsLoadError | null;
};

function customerSafeMetricsError(error: ApiRequestError): MetricsLoadError {
	if (error.status === 401 || error.status === 403) {
		return {
			code: error.status,
			message: 'You are not authorized to view metrics for this index'
		};
	}
	if (error.status === 404) {
		return {
			code: error.status,
			message: 'Metrics are not available for this index yet'
		};
	}
	if (error.status === 429) {
		return {
			code: error.status,
			message: 'Metrics are temporarily unavailable'
		};
	}
	if (error.status >= 500) {
		return {
			code: error.status,
			message: 'Metrics service unavailable'
		};
	}
	return {
		code: error.status,
		message: 'Failed to load metrics'
	};
}

/**
 * Single owner of the customer metrics fetch path for the index-detail route.
 * The UI needs to distinguish "freshly loaded but empty" from "fetch failed",
 * so this loader always returns the same `{ metrics, error }` envelope.
 */
export async function loadMetricsPayload(
	api: ApiClient,
	indexName: string
): Promise<MetricsPayload> {
	try {
		// Keep the metrics fetch behind this seam so tab UI and route tests share
		// the same success/error mapping.
		const metrics = await api.getIndexMetrics(indexName);
		return {
			metrics,
			error: null
		};
	} catch (error) {
		if (error instanceof ApiRequestError) {
			return {
				metrics: null,
				error: customerSafeMetricsError(error)
			};
		}
		return {
			metrics: null,
			error: {
				code: 503,
				message: error instanceof Error ? error.message : 'Metrics service unavailable'
			}
		};
	}
}
