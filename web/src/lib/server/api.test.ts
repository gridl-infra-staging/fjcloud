import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CANONICAL_PUBLIC_API_BASE_URL } from '$lib/public_api';

const { getRequestEventMock } = vi.hoisted(() => ({
	getRequestEventMock: vi.fn()
}));

vi.mock('$app/server', () => ({
	getRequestEvent: getRequestEventMock
}));

describe('createCanonicalPublicApiClient', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('uses the isolated request API for a local public page', async () => {
		getRequestEventMock.mockReturnValue({
			locals: { apiBaseUrl: 'http://127.0.0.1:33183' },
			url: new URL('http://localhost:5183/infrastructure')
		});
		const fetchMock = vi.fn(async () =>
			Response.json({
				overall: { availability_pct: null, total_regions: 0, total_vms: 0 },
				regions: []
			})
		);
		const { createCanonicalPublicApiClient } = await import('./api');

		await createCanonicalPublicApiClient(fetchMock).getPublicInfrastructure();

		expect(fetchMock).toHaveBeenCalledWith('http://127.0.0.1:33183/public/infrastructure', {
			method: 'GET',
			headers: { 'Content-Type': 'application/json' }
		});
	});

	it('keeps the canonical origin for non-local requests', async () => {
		getRequestEventMock.mockReturnValue({
			locals: { apiBaseUrl: 'https://api.staging.flapjack.foo' },
			url: new URL('https://cloud.staging.flapjack.foo/infrastructure')
		});
		const fetchMock = vi.fn(async () =>
			Response.json({
				overall: { availability_pct: null, total_regions: 0, total_vms: 0 },
				regions: []
			})
		);
		const { createCanonicalPublicApiClient } = await import('./api');

		await createCanonicalPublicApiClient(fetchMock).getPublicInfrastructure();

		expect(fetchMock).toHaveBeenCalledWith(
			`${CANONICAL_PUBLIC_API_BASE_URL}/public/infrastructure`,
			{
				method: 'GET',
				headers: { 'Content-Type': 'application/json' }
			}
		);
	});
});
