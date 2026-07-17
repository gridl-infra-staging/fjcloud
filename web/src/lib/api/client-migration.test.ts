import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type { AlgoliaMigrationAvailabilityResponse } from './types';
import { BASE_URL, mockFetch, createAuthenticatedClient } from './client.test.shared';

describe('ApiClient - migration availability', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('GET /migration/algolia/availability returns the typed availability contract', async () => {
		const expected: AlgoliaMigrationAvailabilityResponse = {
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getAlgoliaMigrationAvailability();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/migration/algolia/availability`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});
});
