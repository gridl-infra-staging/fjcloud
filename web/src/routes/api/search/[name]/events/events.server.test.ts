import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const { postPreviewEventMock, createApiClientMock } = vi.hoisted(() => {
	const postPreviewEventMock = vi.fn();
	const createApiClientMock = vi.fn(() => ({ postPreviewEvent: postPreviewEventMock }));
	return { postPreviewEventMock, createApiClientMock };
});

vi.mock('$lib/server/api', () => ({ createApiClient: createApiClientMock }));

import { POST } from './+server';

function event(body: unknown, token: string | null = 'jwt-token'): unknown {
	return {
		request: new Request('http://localhost/api/search/products/events', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body)
		}),
		locals: { user: token ? { token } : null },
		params: { name: 'products' }
	} as never;
}

const validEvent = {
	eventName: 'search_preview_result_opened',
	objectID: 'doc-1',
	position: 21,
	queryID: 'q-123',
	timestamp: 1_700_000_000_000,
	userToken: 'preview-session-123'
};

describe('POST /api/search/[name]/events', () => {
	beforeEach(() => vi.clearAllMocks());

	it('forwards a correlated event through the dashboard session', async () => {
		postPreviewEventMock.mockResolvedValue({ accepted: true });
		const response = await POST(event({ ...validEvent, index: 'attacker-index' }) as never);

		expect(createApiClientMock).toHaveBeenCalledWith('jwt-token');
		expect(postPreviewEventMock).toHaveBeenCalledWith('products', validEvent);
		expect(await response.json()).toEqual({ accepted: true });
	});

	it('rejects unauthenticated event writes', async () => {
		const response = await POST(event(validEvent, null) as never);
		expect(response.status).toBe(401);
		expect(postPreviewEventMock).not.toHaveBeenCalled();
	});

	it('preserves control-plane rejection statuses', async () => {
		postPreviewEventMock.mockRejectedValue(new ApiRequestError(429, 'rate limited'));
		const response = await POST(event(validEvent) as never);
		expect(response.status).toBe(429);
		expect(await response.json()).toEqual({ error: 'rate limited' });
	});
});
