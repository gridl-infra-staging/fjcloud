import { beforeEach, describe, expect, it, vi } from 'vitest';

const fetchMock = vi.hoisted(() => vi.fn());

vi.mock('$lib/server/api', async (importOriginal) => {
	const actual = await importOriginal<typeof import('$lib/server/api')>();
	return {
		...actual,
		createApiClient: vi.fn((token: string | undefined) =>
			actual.createApiClientForBaseUrl(
				'http://fjcloud.test',
				token,
				fetchMock as typeof globalThis.fetch
			)
		)
	};
});

import { rebuildQsConfigAction } from './suggestions-management.server';

describe('suggestions-management server transport', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('rebuildQsConfigAction sends the exact authenticated POST transport contract', async () => {
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ taskID: 27, status: 'queued' }), {
				status: 200,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		const result = await rebuildQsConfigAction({
			indexName: 'products',
			token: 'jwt-token'
		});

		expect(fetchMock).toHaveBeenCalledTimes(1);
		const [url, init] = fetchMock.mock.calls[0];
		expect(url).toBe('http://fjcloud.test/indexes/products/suggestions/build');
		expect(init).toEqual({
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				Authorization: 'Bearer jwt-token'
			}
		});
		expect(init?.body).toBeUndefined();
		expect(result).toEqual({ qsBuildQueued: true });
	});
});
