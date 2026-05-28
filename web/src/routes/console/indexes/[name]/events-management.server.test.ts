import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { makeActionArgs } from './detail.server.test.shared';

const getDebugEventsMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getDebugEvents: getDebugEventsMock
	}))
}));

import { refreshEventsAction } from './events-management.server';

function buildRefreshRequest(formData: FormData): Request {
	return (makeActionArgs('refreshEvents', formData) as { request: Request }).request;
}

describe('events-management refreshEventsAction', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('forwards parsed filters to getDebugEvents', async () => {
		getDebugEventsMock.mockResolvedValue({ events: [], count: 0 });

		const formData = new FormData();
		formData.set('eventType', 'click');
		formData.set('status', 'error');
		formData.set('limit', '50');
		formData.set('from', '1709251200000');
		formData.set('until', '1709337600000');

		const result = await refreshEventsAction({
			request: buildRefreshRequest(formData),
			indexName: 'products',
			token: 'jwt-token'
		});

		expect(getDebugEventsMock).toHaveBeenCalledWith('products', {
			eventType: 'click',
			status: 'error',
			limit: 50,
			from: 1709251200000,
			until: 1709337600000
		});
		expect(result).toEqual({ refreshedEvents: { events: [], count: 0 } });
	});

	it('caps limit to 1000', async () => {
		getDebugEventsMock.mockResolvedValue({ events: [], count: 0 });
		const formData = new FormData();
		formData.set('limit', '2000');

		await refreshEventsAction({
			request: buildRefreshRequest(formData),
			indexName: 'products',
			token: 'jwt-token'
		});

		expect(getDebugEventsMock).toHaveBeenCalledWith(
			'products',
			expect.objectContaining({ limit: 1000 })
		);
	});

	it('maps API failures to default events error', async () => {
		getDebugEventsMock.mockRejectedValue(new ApiRequestError(500, 'upstream failed'));

		const result = await refreshEventsAction({
			request: buildRefreshRequest(new FormData()),
			indexName: 'products',
			token: 'jwt-token'
		});

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ eventsError: 'Failed to fetch events' })
			})
		);
	});
});
