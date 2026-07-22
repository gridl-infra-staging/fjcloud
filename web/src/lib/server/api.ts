import { getRequestEvent } from '$app/server';
import { ApiClient } from '$lib/api/client';
import { deriveApiBaseUrl } from '$lib/config';
import { CANONICAL_PUBLIC_API_BASE_URL } from '$lib/public_api';

const LOCAL_REQUEST_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

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

// Resolve the API base URL for the current request. Prefers locals.apiBaseUrl
// (set by hooks.server.ts from the request hostname) and falls back to deriving
// from event.url.hostname directly. The previous env-var fallback was removed
// because on CF Pages the deployed `staging` and `production` Pages share one
// API_BASE_URL var (the prod URL) — a staging-signed JWT sent to prod's API
// returns 401, which surfaces as a /login?reason=session_expired bounce on
// every protected dashboard route.
export function createApiClient(token?: string, fetchFn?: typeof globalThis.fetch): ApiClient {
	const event = getRequestEvent();
	const apiBaseUrl = event.locals.apiBaseUrl || deriveApiBaseUrl(event.url.hostname);
	return createApiClientForBaseUrl(apiBaseUrl, token, fetchFn);
}

export function createCanonicalPublicApiClient(fetchFn?: typeof globalThis.fetch): ApiClient {
	let publicApiBaseUrl = CANONICAL_PUBLIC_API_BASE_URL;
	try {
		const event = getRequestEvent();
		if (LOCAL_REQUEST_HOSTS.has(event.url.hostname)) {
			publicApiBaseUrl = event.locals.apiBaseUrl || deriveApiBaseUrl(event.url.hostname);
		}
	} catch {
		// Calls outside a request retain the canonical public origin.
	}

	return createApiClientForBaseUrl(publicApiBaseUrl, undefined, fetchFn);
}
