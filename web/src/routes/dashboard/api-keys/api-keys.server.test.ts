import { beforeEach, describe, expect, it, vi } from 'vitest';

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

import { actions } from './+page.server';

describe('API keys page server actions', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('create forwards checked management scopes as raw backend values', async () => {
		createApiKeyMock.mockResolvedValue({
			id: 'key-1',
			name: 'Billing Key',
			key: 'gridl_live_abc123def456abc123def456ab',
			key_prefix: 'gridl_live_abc12',
			scopes: ['indexes:read', 'billing:read'],
			created_at: '2026-03-14T12:00:00Z'
		});

		const form = new FormData();
		form.set('name', ' Billing Key ');
		form.append('scope', 'indexes:read');
		form.append('scope', 'billing:read');

		const request = new Request('http://localhost/dashboard/api-keys?/create', {
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
		expect(result).toEqual({ createdKey: 'gridl_live_abc123def456abc123def456ab' });
	});
});
