import { afterEach, describe, expect, it, vi } from 'vitest';

import { postSearchPreviewEvent } from './analytics_client';

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe('analytics_client', () => {
	it('posts exact /1/events contract with headers, method, and body', async () => {
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
				Authorization: 'Bearer fj_search_123'
			},
			body: JSON.stringify({
				type: 'search_preview_submitted',
				query: 'rust',
				indexName: 'cust_products',
				metadata: { source: 'instantsearch-widget', page: 2 }
			})
		});
	});
});
