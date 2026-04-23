import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { OnboardingStatus } from '$lib/api/types';

const { createIndexMock, generateCredentialsMock, createApiClientMock } = vi.hoisted(() => {
	const createIndex = vi.fn();
	const generateCredentials = vi.fn();
	const createApiClient = vi.fn(() => ({
		createIndex,
		generateCredentials
	}));

	return {
		createIndexMock: createIndex,
		generateCredentialsMock: generateCredentials,
		createApiClientMock: createApiClient
	};
});

vi.mock('$lib/server/api', () => ({
	createApiClient: createApiClientMock
}));

import { actions, load } from './+page.server';

const freeOnboarding: OnboardingStatus = {
	has_payment_method: false,
	has_region: false,
	region_ready: false,
	has_index: false,
	has_api_key: false,
	completed: false,
	billing_plan: 'free',
	free_tier_limits: {
		max_searches_per_month: 50000,
		max_records: 100000,
		max_storage_gb: 10,
		max_indexes: 1
	},
	flapjack_url: null,
	suggested_next_step: 'Create your first index'
};

describe('Onboarding server actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('createIndex does not expose deployment provisioning response shape', async () => {
		createIndexMock.mockResolvedValue({
			name: 'products',
			region: 'us-east-1',
			endpoint: null,
			entries: 0,
			data_size_bytes: 0,
			status: 'provisioning',
			created_at: '2026-02-15T10:00:00Z',
			deployment_id: 'legacy-deployment-id',
			message: 'legacy deployment response'
		});

		const request = new Request('http://localhost/dashboard/onboarding?/createIndex', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.createIndex({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createIndexMock).toHaveBeenCalledWith('products', 'us-east-1');
		expect(result).toMatchObject({
			created: true,
			indexName: 'products',
			region: 'us-east-1'
		});
		expect(result).not.toHaveProperty('provisioning');
		expect(result).not.toHaveProperty('deployment_id');
	});

	it('createIndex returns a generic 500 failure for unexpected upstream errors', async () => {
		createIndexMock.mockRejectedValue(new Error('connect ECONNREFUSED 127.0.0.1:3001'));

		const request = new Request('http://localhost/dashboard/onboarding?/createIndex', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.createIndex({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 500,
				data: { error: 'Failed to create index' }
			})
		);
	});

	it('getCredentials preserves upstream 400 messages from the API boundary', async () => {
		generateCredentialsMock.mockRejectedValue(
			new ApiRequestError(400, 'Create an index first')
		);

		const result = await actions.getCredentials({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Create an index first' }
			})
		);
	});

	it('createIndex returns shared session-expired shape on 401', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const request = new Request('http://localhost/dashboard/onboarding?/createIndex', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.createIndex({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('getCredentials returns shared session-expired shape on 403', async () => {
		generateCredentialsMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await actions.getCredentials({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Forbidden'
				})
			})
		);
	});

	it('getCredentials returns a generic 500 failure for unexpected upstream errors', async () => {
		generateCredentialsMock.mockRejectedValue(new Error('upstream timeout'));

		const result = await actions.getCredentials({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 500,
				data: { error: 'Failed to generate credentials' }
			})
		);
	});
});

describe('Onboarding server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('reads onboarding status from parent() contract', async () => {
		const parent = vi.fn().mockResolvedValue({
			onboardingStatus: freeOnboarding,
			planContext: {
				billing_plan: 'free',
				free_tier_limits: freeOnboarding.free_tier_limits,
				has_payment_method: false,
				onboarding_completed: false
			}
		});

		const result = (await load({ parent } as never))!;

		expect(parent).toHaveBeenCalledOnce();
		expect(result).toEqual({});
		expect(createApiClientMock).not.toHaveBeenCalled();
	});

	it('does not redirect completed users away from the credential handoff page', async () => {
		const parent = vi.fn().mockResolvedValue({
			onboardingStatus: freeOnboarding,
			planContext: {
				billing_plan: 'shared',
				free_tier_limits: null,
				has_payment_method: true,
				onboarding_completed: true
			}
		});

		await expect(load({ parent } as never)).resolves.toEqual({});
	});

	it('createIndex retries transient 429 responses before succeeding', async () => {
		createIndexMock
			.mockRejectedValueOnce(new ApiRequestError(429, 'too many requests'))
			.mockResolvedValueOnce({
				name: 'products',
				region: 'us-east-1'
			});

		const request = new Request('http://localhost/dashboard/onboarding?/createIndex', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.createIndex({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createIndexMock).toHaveBeenCalledTimes(2);
		expect(result).toMatchObject({
			created: true,
			indexName: 'products',
			region: 'us-east-1'
		});
	});

	it('getCredentials retries transient 429 responses before succeeding', async () => {
		generateCredentialsMock
			.mockRejectedValueOnce(new ApiRequestError(429, 'too many requests'))
			.mockResolvedValueOnce({
				endpoint: 'http://127.0.0.1:7700',
				api_key: 'fj_live_123',
				application_id: 'griddle'
			});

		const result = await actions.getCredentials({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(generateCredentialsMock).toHaveBeenCalledTimes(2);
		expect(result).toEqual({
			credentials: {
				endpoint: 'http://127.0.0.1:7700',
				api_key: 'fj_live_123',
				application_id: 'griddle'
			}
		});
	});
});
