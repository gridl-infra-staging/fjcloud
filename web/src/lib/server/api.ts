import { ApiClient } from '$lib/api/client';
import { getApiBaseUrl } from '$lib/config';
import { CANONICAL_PUBLIC_API_BASE_URL } from '$lib/public_api';

export function createApiClientForBaseUrl(
	baseUrl: string,
	token?: string,
	fetchFn?: typeof globalThis.fetch
): ApiClient {
	const client = new ApiClient(baseUrl, token);
	if (fetchFn) {
		client.setFetch(fetchFn);
	}
	return client;
}

export function createApiClient(token?: string, fetchFn?: typeof globalThis.fetch): ApiClient {
	return createApiClientForBaseUrl(getApiBaseUrl(), token, fetchFn);
}

export function createCanonicalPublicApiClient(fetchFn?: typeof globalThis.fetch): ApiClient {
	return createApiClientForBaseUrl(CANONICAL_PUBLIC_API_BASE_URL, undefined, fetchFn);
}
