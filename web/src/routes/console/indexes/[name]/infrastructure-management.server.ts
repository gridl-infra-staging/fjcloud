import { ApiRequestError, type ApiClient } from '$lib/api/client';
import type { IndexInfrastructureResponse } from '$lib/api/types';

export type InfrastructureLoadError = {
	code: number;
	message: string;
};

export type InfrastructurePayload = {
	infrastructure: IndexInfrastructureResponse | null;
	error: InfrastructureLoadError | null;
};

function customerSafeInfrastructureError(error: ApiRequestError): InfrastructureLoadError {
	if (error.status === 401 || error.status === 403) {
		return {
			code: error.status,
			message: 'You are not authorized to view infrastructure for this index'
		};
	}
	if (error.status === 404) {
		return {
			code: error.status,
			message: 'Infrastructure is not available for this index yet'
		};
	}
	if (error.status === 429) {
		return {
			code: error.status,
			message: 'Infrastructure is temporarily unavailable'
		};
	}
	if (error.status >= 500) {
		return {
			code: error.status,
			message: 'Infrastructure service unavailable'
		};
	}
	return {
		code: error.status,
		message: 'Failed to load infrastructure'
	};
}

/** Loads the customer-safe Infrastructure envelope for the index-detail route. */
export async function loadInfrastructurePayload(
	api: ApiClient,
	indexName: string
): Promise<InfrastructurePayload> {
	try {
		return {
			infrastructure: await api.getIndexInfrastructure(indexName),
			error: null
		};
	} catch (error) {
		return {
			infrastructure: null,
			error:
				error instanceof ApiRequestError
					? customerSafeInfrastructureError(error)
					: { code: 503, message: 'Infrastructure service unavailable' }
		};
	}
}
