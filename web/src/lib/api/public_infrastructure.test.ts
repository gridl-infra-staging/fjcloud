import { describe, expect, it } from 'vitest';
import { BASE_URL, createAuthenticatedClient, mockFetch } from './client.test.shared';

describe('ApiClient public infrastructure', () => {
	it('omits auth and preserves nullable public values', async () => {
		const authenticatedClient = createAuthenticatedClient();
		const expected = {
			overall: {
				availability_pct: null,
				total_regions: 1,
				total_vms: 0
			},
			regions: [
				{
					region: 'us-east-1',
					provider: 'aws',
					display_name: 'US East',
					provider_location: 'N. Virginia',
					health: 'unknown',
					utilization: null,
					vm_count: 0
				}
			]
		};
		const fetch = mockFetch(200, expected);
		authenticatedClient.setFetch(fetch);

		const result = await authenticatedClient.getPublicInfrastructure();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/public/infrastructure`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json' }
		});
		expect(result).toEqual(expected);
		expect(result.overall.availability_pct).toBeNull();
		expect(result.regions[0].utilization).toBeNull();
	});
});
