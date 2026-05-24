import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const createApiKeyMock = vi.fn();
const getApiKeysMock = vi.fn();
const deleteApiKeyMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		createApiKey: createApiKeyMock,
		getApiKeys: getApiKeysMock,
		deleteApiKey: deleteApiKeyMock
	}))
}));

import { EMPTY_SCOPE_REQUIRED_ERROR, actions, load } from './+page.server';

describe('API keys page server actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('create forwards checked management scopes as raw backend values', async () => {
		createApiKeyMock.mockResolvedValue({
			id: 'key-1',
			name: 'Billing Key',
			key: 'fjc_live_abc123def456abc123def456ab',
			key_prefix: 'fjc_live_abc1234',
			scopes: ['indexes:read', 'billing:read'],
			created_at: '2026-03-14T12:00:00Z'
		});

		const form = new FormData();
		form.set('name', ' Billing Key ');
		form.append('scope', 'indexes:read');
		form.append('scope', 'billing:read');

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
			scopes: ['indexes:read', 'billing:read']
		});
		expect(result).toEqual({ createdKey: 'fjc_live_abc123def456abc123def456ab' });
	});

	it('load redirects to login when api key fetch hits an expired session', async () => {
		getApiKeysMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		await expect(load({ locals: { user: { token: 'jwt-token' } } } as never)).rejects.toMatchObject(
			{
				status: 303,
				location: '/login?reason=session_expired'
			}
		);
	});

	it('load returns a customer-facing error instead of a false empty-state success', async () => {
		getApiKeysMock.mockRejectedValue(new ApiRequestError(503, 'Backend temporarily unavailable'));

		const result = await load({ locals: { user: { token: 'jwt-token' } } } as never);

		expect(result).toEqual({
			apiKeys: [],
			loadError: 'Backend temporarily unavailable'
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
