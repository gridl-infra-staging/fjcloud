import { afterEach, describe, expect, it, vi } from 'vitest';

import { postSearchPreviewEvent } from './analytics_client';

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('analytics_client', () => {
	it('posts exact /1/events contract with headers, method, and body', async () => {
		vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000);
		const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 202 });
		vi.stubGlobal('fetch', fetchMock);

		await postSearchPreviewEvent('http://127.0.0.1:7700/', 'fj_search_123', {
			type: 'search_preview_submitted',
			query: 'rust',
			indexName: 'cust_products',
			metadata: { source: 'instantsearch-widget', page: 2 }
		});

		expect(fetchMock).toHaveBeenCalledWith('http://127.0.0.1:7700/1/events', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json',
				'X-Algolia-API-Key': 'fj_search_123',
				'X-Algolia-Application-Id': 'flapjack',
				Authorization: 'Bearer fj_search_123'
			},
			body: JSON.stringify({
				events: [
					{
						eventType: 'click',
						eventName: 'search_preview_submitted',
						index: 'cust_products',
						userToken: 'search-preview',
						objectIDs: ['missing-object-id'],
						positions: [1],
						timestamp: 1_700_000_000_000
					}
				]
			})
		});
	});

	it('throws a status-bearing error when the analytics endpoint rejects the event', async () => {
		const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 429 });
		vi.stubGlobal('fetch', fetchMock);

		await expect(
			postSearchPreviewEvent('http://127.0.0.1:7700/', 'fj_search_123', {
				type: 'search_preview_submitted',
				query: 'rust',
				indexName: 'cust_products',
				metadata: { source: 'instantsearch-widget', page: 2 }
			})
		).rejects.toThrow('Search preview analytics failed: 429');
	});
});
