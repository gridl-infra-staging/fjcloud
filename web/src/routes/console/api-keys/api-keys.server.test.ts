import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const createApiKeyMock = vi.fn();
const getApiKeysMock = vi.fn();
const getIndexesMock = vi.fn();
const deleteApiKeyMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		createApiKey: createApiKeyMock,
		getApiKeys: getApiKeysMock,
		getIndexes: getIndexesMock,
		deleteApiKey: deleteApiKeyMock
	}))
}));

import { EMPTY_SCOPE_REQUIRED_ERROR } from './api_keys_constants';
import { actions, load } from './+page.server';

describe('API keys page server actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('create forwards managed-key parity fields with backend snake_case keys', async () => {
		createApiKeyMock.mockResolvedValue({
			id: 'key-1',
			name: 'Billing Key',
			description: 'prod traffic key',
			key: 'fjc_live_abc123def456abc123def456ab',
			key_prefix: 'fjc_live_abc1234',
			scopes: ['indexes:read', 'billing:read'],
			indexes: ['products', 'orders'],
			restrict_sources: ['10.0.0.0/24', '192.168.1.10'],
			expires_at: '2026-07-01T00:00:00Z',
			max_hits_per_query: 250,
			max_queries_per_ip_per_hour: 5000,
			created_at: '2026-03-14T12:00:00Z'
		});

		const form = new FormData();
		form.set('name', ' Billing Key ');
		form.append('scope', 'indexes:read');
		form.append('scope', 'billing:read');
		form.set('description', ' prod traffic key ');
		form.append('indexes', 'products');
		form.append('indexes', 'orders');
		form.append('restrict_sources', '10.0.0.0/24');
		form.append('restrict_sources', '192.168.1.10');
		form.set('expires_at', '2026-07-01T00:00:00Z');
		form.set('max_hits_per_query', '250');
		form.set('max_queries_per_ip_per_hour', '5000');

		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createApiKeyMock).toHaveBeenCalledWith({
			name: 'Billing Key',
			scopes: ['indexes:read', 'billing:read'],
			description: 'prod traffic key',
			indexes: ['products', 'orders'],
			restrict_sources: ['10.0.0.0/24', '192.168.1.10'],
			expires_at: '2026-07-01T00:00:00Z',
			max_hits_per_query: 250,
			max_queries_per_ip_per_hour: 5000
		});
		expect(result).toEqual({
			createdKey: 'fjc_live_abc123def456abc123def456ab',
			createdKeyId: 'key-1'
		});
	});

	it('create normalizes blank optional managed-key fields to null-or-empty payload values', async () => {
		createApiKeyMock.mockResolvedValue({
			id: 'key-1',
			name: 'Billing Key',
			description: null,
			key: 'fjc_live_abc123def456abc123def456ab',
			key_prefix: 'fjc_live_abc1234',
			scopes: ['indexes:read'],
			indexes: [],
			restrict_sources: [],
			expires_at: null,
			max_hits_per_query: null,
			max_queries_per_ip_per_hour: null,
			created_at: '2026-03-14T12:00:00Z'
		});

		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		form.set('description', '   ');
		form.append('indexes', '  ');
		form.append('restrict_sources', '');
		form.set('expires_at', '');
		form.set('max_hits_per_query', ' ');
		form.set('max_queries_per_ip_per_hour', '');

		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createApiKeyMock).toHaveBeenCalledWith({
			name: 'Billing Key',
			scopes: ['indexes:read'],
			description: null,
			indexes: [],
			restrict_sources: [],
			expires_at: null,
			max_hits_per_query: null,
			max_queries_per_ip_per_hour: null
		});
	});

	it('create normalizes browser datetime-local expires_at values to UTC RFC3339', async () => {
		createApiKeyMock.mockResolvedValue({
			id: 'key-1',
			name: 'Billing Key',
			description: null,
			key: 'fjc_live_abc123def456abc123def456ab',
			key_prefix: 'fjc_live_abc1234',
			scopes: ['indexes:read'],
			indexes: [],
			restrict_sources: [],
			expires_at: '2026-07-01T00:00:00Z',
			max_hits_per_query: null,
			max_queries_per_ip_per_hour: null,
			created_at: '2026-03-14T12:00:00Z'
		});

		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		form.set('expires_at', '2026-07-01T00:00');
		form.set('expires_at_timezone_offset_minutes', '60');

		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		const expectedRfc3339 = '2026-07-01T01:00:00Z';
		expect(createApiKeyMock).toHaveBeenCalledWith(
			expect.objectContaining({
				expires_at: expectedRfc3339
			})
		);
	});

	it('create converts datetime-local expires_at using submitted selected-time offset for cross-DST dates', async () => {
		createApiKeyMock.mockResolvedValue({
			id: 'key-1',
			name: 'Billing Key',
			description: null,
			key: 'fjc_live_abc123def456abc123def456ab',
			key_prefix: 'fjc_live_abc1234',
			scopes: ['indexes:read'],
			indexes: [],
			restrict_sources: [],
			expires_at: '2026-01-15T05:00:00Z',
			max_hits_per_query: null,
			max_queries_per_ip_per_hour: null,
			created_at: '2026-03-14T12:00:00Z'
		});

		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		form.set('expires_at', '2026-01-15T00:00');
		form.set('expires_at_timezone_offset_minutes', '300');

		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createApiKeyMock).toHaveBeenCalledWith(
			expect.objectContaining({
				expires_at: '2026-01-15T05:00:00Z'
			})
		);
	});

	it('create rejects malformed datetime-local expires_at component values', async () => {
		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		form.set('expires_at', '2026-13-10T25:30');
		form.set('expires_at_timezone_offset_minutes', '60');

		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toMatchObject({
			status: 400,
			data: { error: 'expires_at must be a valid date-time' }
		});
		expect(createApiKeyMock).not.toHaveBeenCalled();
	});

	it('create rejects non-positive numeric managed-key limits before the API call', async () => {
		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		form.set('max_hits_per_query', '0');
		form.set('max_queries_per_ip_per_hour', '-1');

		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			status: 400,
			data: { error: 'max_hits_per_query must be at least 1' }
		});
		expect(createApiKeyMock).not.toHaveBeenCalled();
	});

	it('load returns API keys plus index options for managed-key form inputs', async () => {
		const apiKeys = [
			{
				id: 'key-1',
				name: 'Prod Key',
				description: 'prod traffic key',
				key_prefix: 'fjc_live_abc1234',
				scopes: ['indexes:read'],
				indexes: ['products'],
				restrict_sources: ['10.0.0.0/24'],
				expires_at: '2026-07-01T00:00:00Z',
				max_hits_per_query: 50,
				max_queries_per_ip_per_hour: 1000,
				last_used_at: null,
				created_at: '2026-03-14T12:00:00Z'
			}
		];
		const indexOptions = [
			{
				name: 'products',
				region: 'us-east-1',
				endpoint: null,
				entries: 5000,
				data_size_bytes: 32000,
				status: 'ready',
				tier: 'hot',
				created_at: '2026-03-14T12:00:00Z'
			}
		];
		getApiKeysMock.mockResolvedValue(apiKeys);
		getIndexesMock.mockResolvedValue(indexOptions);

		const result = await load({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('http://localhost/console/api-keys')
		} as never);

		expect(result).toEqual({ apiKeys, indexOptions, selectedIndexFilter: '' });
		expect(getApiKeysMock).toHaveBeenCalledTimes(1);
		expect(getIndexesMock).toHaveBeenCalledTimes(1);
	});

	it('load preserves the selected index filter from the URL for parity filtering', async () => {
		getApiKeysMock.mockResolvedValue([]);
		getIndexesMock.mockResolvedValue([]);

		const result = await load({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('http://localhost/console/api-keys?index=products')
		} as never);

		expect(result).toEqual({ apiKeys: [], indexOptions: [], selectedIndexFilter: 'products' });
	});

	it('load redirects to login when api key fetch hits an expired session', async () => {
		getApiKeysMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		await expect(
			load({
				locals: { user: { token: 'jwt-token' } },
				url: new URL('http://localhost/console/api-keys')
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=session_expired'
		});
	});

	it('load returns a customer-facing error instead of a false empty-state success', async () => {
		getApiKeysMock.mockRejectedValue(new ApiRequestError(503, 'Backend temporarily unavailable'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('http://localhost/console/api-keys')
		} as never);

		expect(result).toEqual({
			apiKeys: [],
			indexOptions: [],
			selectedIndexFilter: '',
			loadError: 'Backend temporarily unavailable'
		});
	});

	it('load falls back to empty index options when index fetch fails but API keys succeeded', async () => {
		const apiKeys = [
			{
				id: 'key-1',
				name: 'Prod Key',
				description: null,
				key_prefix: 'fjc_live_abc1234',
				scopes: ['indexes:read'],
				indexes: [],
				restrict_sources: [],
				expires_at: null,
				max_hits_per_query: null,
				max_queries_per_ip_per_hour: null,
				last_used_at: null,
				created_at: '2026-03-14T12:00:00Z'
			}
		];
		getApiKeysMock.mockResolvedValue(apiKeys);
		getIndexesMock.mockRejectedValue(new Error('index discovery unavailable'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } },
			url: new URL('http://localhost/console/api-keys')
		} as never);

		expect(result).toEqual({ apiKeys, indexOptions: [], selectedIndexFilter: '' });
	});

	it('load redirects when index fetch hits an expired session even if API keys loaded', async () => {
		getApiKeysMock.mockResolvedValue([]);
		getIndexesMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		await expect(
			load({
				locals: { user: { token: 'jwt-token' } },
				url: new URL('http://localhost/console/api-keys')
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=session_expired'
		});
	});

	it('create action returns shared session-expired failure payload for expired sessions', async () => {
		createApiKeyMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toMatchObject({
			status: 401,
			data: {
				_authSessionExpired: true
			}
		});
	});

	it('create rejects before API call when no scopes are selected', async () => {
		const form = new FormData();
		form.set('name', 'Billing Key');
		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			status: 400,
			data: { error: EMPTY_SCOPE_REQUIRED_ERROR }
		});
		expect(createApiKeyMock).not.toHaveBeenCalled();
	});

	it('create preserves backend validation message for empty scope responses', async () => {
		const backendValidationMessage = 'choose at least one scope for this key';
		createApiKeyMock.mockRejectedValue(
			new ApiRequestError(400, backendValidationMessage, {
				body: { error: backendValidationMessage }
			})
		);

		const form = new FormData();
		form.set('name', 'Billing Key');
		form.append('scope', 'indexes:read');
		const request = new Request('http://localhost/console/api-keys?/create', {
			method: 'POST',
			body: form
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			status: 400,
			data: { error: backendValidationMessage }
		});
		expect(result).not.toEqual({
			status: 400,
			data: { error: EMPTY_SCOPE_REQUIRED_ERROR }
		});
	});

	it('revoke action returns success when delete errors after removing the key', async () => {
		deleteApiKeyMock.mockRejectedValue(new ApiRequestError(500, 'upstream closed'));
		getApiKeysMock.mockResolvedValue([
			{
				id: 'key-2',
				name: 'Other Key',
				key_prefix: 'fjc_live_other',
				scopes: ['indexes:read'],
				indexes: [],
				restrict_sources: [],
				description: null,
				expires_at: null,
				max_hits_per_query: null,
				max_queries_per_ip_per_hour: null,
				last_used_at: null,
				created_at: '2026-03-14T12:00:00Z'
			}
		]);

		const form = new FormData();
		form.set('keyId', 'key-1');
		form.set('keyName', 'Billing Key');
		const request = new Request('http://localhost/console/api-keys?/revoke', {
			method: 'POST',
			body: form
		});

		const result = await actions.revoke({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({ revokedKeyName: 'Billing Key' });
		expect(deleteApiKeyMock).toHaveBeenCalledWith('key-1');
		expect(getApiKeysMock).toHaveBeenCalledTimes(1);
	});

	it('revoke action preserves failure when delete errors and the key still exists', async () => {
		deleteApiKeyMock.mockRejectedValue(new ApiRequestError(500, 'upstream closed'));
		getApiKeysMock.mockResolvedValue([
			{
				id: 'key-1',
				name: 'Billing Key',
				key_prefix: 'fjc_live_billing',
				scopes: ['indexes:read'],
				indexes: [],
				restrict_sources: [],
				description: null,
				expires_at: null,
				max_hits_per_query: null,
				max_queries_per_ip_per_hour: null,
				last_used_at: null,
				created_at: '2026-03-14T12:00:00Z'
			}
		]);

		const form = new FormData();
		form.set('keyId', 'key-1');
		form.set('keyName', 'Billing Key');
		const request = new Request('http://localhost/console/api-keys?/revoke', {
			method: 'POST',
			body: form
		});

		const result = await actions.revoke({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual({
			status: 400,
			data: { error: 'Failed to revoke API key' }
		});
	});

	it('revoke action returns shared session-expired failure payload for expired sessions', async () => {
		deleteApiKeyMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const form = new FormData();
		form.set('keyId', 'key-1');
		const request = new Request('http://localhost/console/api-keys?/revoke', {
			method: 'POST',
			body: form
		});

		const result = await actions.revoke({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toMatchObject({
			status: 401,
			data: {
				_authSessionExpired: true
			}
		});
	});
});
