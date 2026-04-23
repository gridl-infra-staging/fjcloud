import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient, ApiRequestError } from './client';
import type { AlgoliaIndexListResponse, AlgoliaMigrateResponse } from './types';
import { BASE_URL, mockFetch, createAuthenticatedClient } from './client.test.shared';

describe('ApiClient - migration endpoints', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('POST /migration/algolia/list-indexes sends appId and apiKey', async () => {
		const expected: AlgoliaIndexListResponse = {
			indexes: [
				{ name: 'products', entries: 5000, lastBuildTimeS: 12 },
				{ name: 'users', entries: 200, lastBuildTimeS: 3 }
			]
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.listAlgoliaIndexes({
			appId: 'ALGOLIA_APP',
			apiKey: 'ALGOLIA_KEY'
		});

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/list-indexes`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({ appId: 'ALGOLIA_APP', apiKey: 'ALGOLIA_KEY' })
		});
		expect(result).toEqual(expected);
	});

	it('POST /migration/algolia/migrate sends appId, apiKey, and sourceIndex', async () => {
		const expected: AlgoliaMigrateResponse = {
			taskId: 'task-abc-123',
			message: 'Migration started'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.migrateFromAlgolia({
			appId: 'ALGOLIA_APP',
			apiKey: 'ALGOLIA_KEY',
			sourceIndex: 'products'
		});

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/migrate`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({ appId: 'ALGOLIA_APP', apiKey: 'ALGOLIA_KEY', sourceIndex: 'products' })
		});
		expect(result).toEqual(expected);
	});

	it('listAlgoliaIndexes propagates 503 as ApiRequestError', async () => {
		const fetch = mockFetch(503, { error: 'No active deployment available' });
		client.setFetch(fetch);

		try {
			await client.listAlgoliaIndexes({ appId: 'APP', apiKey: 'KEY' });
			expect.unreachable('should have thrown');
		} catch (err) {
			expect(err).toBeInstanceOf(ApiRequestError);
			expect((err as ApiRequestError).status).toBe(503);
			expect((err as ApiRequestError).message).toBe('No active deployment available');
		}
	});

	it('migrateFromAlgolia propagates 503 as ApiRequestError', async () => {
		const fetch = mockFetch(503, { error: 'No active deployment available' });
		client.setFetch(fetch);

		try {
			await client.migrateFromAlgolia({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'idx' });
			expect.unreachable('should have thrown');
		} catch (err) {
			expect(err).toBeInstanceOf(ApiRequestError);
			expect((err as ApiRequestError).status).toBe(503);
			expect((err as ApiRequestError).message).toBe('No active deployment available');
		}
	});
});
