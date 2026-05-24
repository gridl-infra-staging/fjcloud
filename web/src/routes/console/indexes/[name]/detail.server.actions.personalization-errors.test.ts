import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { makeActionArgs } from './detail.server.test.shared';

const deletePersonalizationStrategyMock = vi.fn();
const getPersonalizationProfileMock = vi.fn();
const deletePersonalizationProfileMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		deletePersonalizationStrategy: deletePersonalizationStrategyMock,
		getPersonalizationProfile: getPersonalizationProfileMock,
		deletePersonalizationProfile: deletePersonalizationProfileMock
	}))
}));

import { actions } from './+page.server';

describe('Index detail page server -- personalization action API errors', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('deletePersonalizationStrategy action returns fail on API error', async () => {
		deletePersonalizationStrategyMock.mockRejectedValue(new Error('upstream failed'));

		const result = await actions.deletePersonalizationStrategy(
			makeActionArgs('deletePersonalizationStrategy', new FormData()) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ personalizationError: 'upstream failed' })
			})
		);
	});

	it('getPersonalizationProfile action returns fail on API error', async () => {
		getPersonalizationProfileMock.mockRejectedValue(new Error('upstream failed'));

		const formData = new FormData();
		formData.set('userToken', 'user_abc');

		const result = await actions.getPersonalizationProfile(
			makeActionArgs('getPersonalizationProfile', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ personalizationError: 'upstream failed' })
			})
		);
	});

	it('deletePersonalizationProfile action returns fail on API error', async () => {
		deletePersonalizationProfileMock.mockRejectedValue(new Error('upstream failed'));

		const formData = new FormData();
		formData.set('userToken', 'user_abc');

		const result = await actions.deletePersonalizationProfile(
			makeActionArgs('deletePersonalizationProfile', formData) as never
		);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({ personalizationError: 'upstream failed' })
			})
		);
	});

	it('deletePersonalizationStrategy action returns shared session failure for 403 upstream auth errors', async () => {
		deletePersonalizationStrategyMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await actions.deletePersonalizationStrategy(
			makeActionArgs('deletePersonalizationStrategy', new FormData()) as never
		);

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
});
