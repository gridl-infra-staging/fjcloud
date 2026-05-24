import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type { OnboardingStatus, FlapjackCredentials } from './types';
import { BASE_URL, mockFetch, createAuthenticatedClient } from './client.test.shared';

// Onboarding endpoint coverage extracted from client.test.ts to keep
// that file under the 800-line size cap.
describe('ApiClient onboarding endpoints', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('GET /onboarding/status returns onboarding state', async () => {
		const expected: OnboardingStatus = {
			has_payment_method: true,
			has_region: true,
			region_ready: true,
			has_index: true,
			has_api_key: true,
			completed: true,
			billing_plan: 'free',
			free_tier_limits: {
				max_searches_per_month: 50000,
				max_records: 100000,
				max_storage_mb: 250,
				max_indexes: 3
			},
			flapjack_url: 'https://vm-abc.flapjack.foo',
			suggested_next_step: "You're all set!"
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getOnboardingStatus();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/onboarding/status`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('normalizes legacy free_tier_limits.max_storage_gb to max_storage_mb at the client boundary', async () => {
		const legacyPayload = {
			has_payment_method: true,
			has_region: true,
			region_ready: true,
			has_index: true,
			has_api_key: true,
			completed: true,
			billing_plan: 'free',
			free_tier_limits: {
				max_searches_per_month: 50000,
				max_records: 100000,
				max_storage_gb: 250 / 1024,
				max_indexes: 3
			},
			flapjack_url: 'https://vm-abc.flapjack.foo',
			suggested_next_step: "You're all set!"
		};
		const fetch = mockFetch(200, legacyPayload);
		client.setFetch(fetch);

		const result = await client.getOnboardingStatus();

		expect(result).toEqual({
			has_payment_method: true,
			has_region: true,
			region_ready: true,
			has_index: true,
			has_api_key: true,
			completed: true,
			billing_plan: 'free',
			free_tier_limits: {
				max_searches_per_month: 50000,
				max_records: 100000,
				max_storage_mb: 250,
				max_indexes: 3
			},
			flapjack_url: 'https://vm-abc.flapjack.foo',
			suggested_next_step: "You're all set!"
		});
		expect(result.free_tier_limits).not.toHaveProperty('max_storage_gb');
	});

	it('POST /onboarding/credentials returns credentials', async () => {
		const expected: FlapjackCredentials = {
			endpoint: 'https://vm-abc.flapjack.foo',
			api_key: 'fj_search_abc123',
			application_id: 'flapjack'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.generateCredentials();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/onboarding/credentials`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: undefined
		});
		expect(result).toEqual(expected);
	});
});
