import { vi } from 'vitest';
import { ApiClient } from './client';

export const BASE_URL = 'http://localhost:3000';

export function mockFetch(status: number, body: unknown): typeof globalThis.fetch {
	return vi.fn().mockResolvedValue({
		ok: status >= 200 && status < 300,
		status,
		json: () => Promise.resolve(body)
	});
}

export function createAuthenticatedClient(): ApiClient {
	return new ApiClient(BASE_URL, 'my-jwt-token');
}

export function createClient(): ApiClient {
	return new ApiClient(BASE_URL);
}
