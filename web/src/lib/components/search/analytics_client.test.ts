import { afterEach, describe, expect, it, vi } from 'vitest';

import { getSearchPreviewSessionToken, postSearchPreviewEvent } from './analytics_client';

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('analytics_client', () => {
	it('posts exact correlated event through same origin without engine credentials', async () => {
		vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000);
		const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 202 });
		vi.stubGlobal('fetch', fetchMock);

		await postSearchPreviewEvent('products', {
			eventName: 'search_preview_result_opened',
			objectID: 'doc-1',
			position: 21,
			queryID: 'q-123',
			userToken: 'preview-session-123'
		});

		expect(fetchMock).toHaveBeenCalledWith('/api/search/products/events', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: expect.any(String)
		});
		expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
			eventName: 'search_preview_result_opened',
			objectID: 'doc-1',
			position: 21,
			queryID: 'q-123',
			timestamp: 1_700_000_000_000,
			userToken: 'preview-session-123'
		});
		expect(JSON.stringify(fetchMock.mock.calls[0])).not.toContain('X-Algolia-API-Key');
	});

	it('reuses a token within one session and separates browser sessions', () => {
		const values = new Map<string, string>();
		vi.stubGlobal('sessionStorage', {
			getItem: vi.fn((key: string) => values.get(key) ?? null),
			setItem: vi.fn((key: string, value: string) => values.set(key, value))
		});
		vi.spyOn(globalThis.crypto, 'randomUUID')
			.mockReturnValueOnce('11111111-1111-4111-8111-111111111111')
			.mockReturnValueOnce('22222222-2222-4222-8222-222222222222');

		const firstAction = getSearchPreviewSessionToken();
		expect(getSearchPreviewSessionToken()).toBe(firstAction);
		values.clear();
		const secondSession = getSearchPreviewSessionToken();

		expect(firstAction).not.toBe(secondSession);
	});

	it('event delivery failures remain visible and are not classified as success', async () => {
		const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 429 });
		vi.stubGlobal('fetch', fetchMock);

		await expect(
			postSearchPreviewEvent('products', {
				eventName: 'search_preview_result_opened',
				objectID: 'doc-1',
				position: 1,
				queryID: 'q-123',
				userToken: 'preview-session-123'
			})
		).rejects.toThrow('Search preview analytics failed: 429');
	});
});
