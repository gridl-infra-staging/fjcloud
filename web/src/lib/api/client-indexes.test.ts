import { describe, it, expect, beforeEach } from 'vitest';
import { ApiClient } from './client';
import type {
	Index,
	SearchResult,
	InternalRegion,
	Rule,
	RuleSearchResponse,
	Synonym,
	SynonymSearchResponse,
	QsConfig,
	QsBuildStatus,
	FlapjackApiKey,
	DictionarySearchRequest,
	DictionarySearchResponse,
	DictionaryBatchRequest,
	DictionaryBatchResponse
} from './types';
import { BASE_URL, mockFetch, createAuthenticatedClient } from './client.test.shared';

describe('ApiClient - index endpoints', () => {
	let client: ApiClient;

	beforeEach(() => {
		client = createAuthenticatedClient();
	});

	it('GET /internal/regions returns available regions with provider metadata', async () => {
		const expected: InternalRegion[] = [
			{
				id: 'us-east-1',
				display_name: 'US East (Virginia)',
				provider: 'aws',
				provider_location: 'us-east-1',
				available: true
			},
			{
				id: 'eu-central-1',
				display_name: 'EU Central (Germany)',
				provider: 'hetzner',
				provider_location: 'fsn1',
				available: true
			}
		];
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getInternalRegions();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/internal/regions`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('GET /indexes returns list of indexes', async () => {
		const expected: Index[] = [
			{
				name: 'products',
				region: 'us-east-1',
				endpoint: 'https://vm-abc.flapjack.foo',
				entries: 1500,
				data_size_bytes: 204800,
				status: 'ready',
				tier: 'active',
				created_at: '2026-02-15T10:00:00Z'
			}
		];
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getIndexes();

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('GET /indexes/:name returns single index', async () => {
		const expected: Index = {
			name: 'products',
			region: 'us-east-1',
			endpoint: 'https://vm-abc.flapjack.foo',
			entries: 1500,
			data_size_bytes: 204800,
			status: 'ready',
			tier: 'active',
			created_at: '2026-02-15T10:00:00Z'
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getIndex('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('POST /indexes sends name and region', async () => {
		const expected: Index = {
			name: 'products',
			region: 'us-east-1',
			endpoint: 'https://vm-abc.flapjack.foo',
			entries: 0,
			data_size_bytes: 0,
			status: 'ready',
			tier: 'active',
			created_at: '2026-02-15T10:00:00Z'
		};
		const fetch = mockFetch(201, expected);
		client.setFetch(fetch);

		const result = await client.createIndex('products', 'us-east-1');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({ name: 'products', region: 'us-east-1' })
		});
		expect(result).toEqual(expected);
	});

	it('DELETE /indexes/:name sends confirm body', async () => {
		const fetch = mockFetch(204, {});
		client.setFetch(fetch);

		await client.deleteIndex('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products`, {
			method: 'DELETE',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({ confirm: true })
		});
	});

	it('POST /indexes/:name/search sends query', async () => {
		const expected: SearchResult = { hits: [{ name: 'Widget' }], nbHits: 1, processingTimeMs: 5 };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.testSearch('products', { query: 'widget' });

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/search`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({ query: 'widget' })
		});
		expect(result).toEqual(expected);
	});

	it('POST /indexes/:name/search forwards structured params', async () => {
		const expected: SearchResult = {
			hits: [{ name: 'Laptop' }],
			nbHits: 42,
			page: 2,
			hitsPerPage: 5,
			facets: { category: { electronics: 42 } }
		};
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.testSearch('products', {
			query: 'laptop',
			page: 2,
			hitsPerPage: 5,
			facets: ['category'],
			facetFilters: [['category:electronics']]
		});

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/search`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify({
				query: 'laptop',
				page: 2,
				hitsPerPage: 5,
				facets: ['category'],
				facetFilters: [['category:electronics']]
			})
		});
		expect(result).toEqual(expected);
	});

	it('GET /indexes/:name/settings returns settings', async () => {
		const expected = { searchableAttributes: ['title', 'description'] };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.getIndexSettings('products');

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/settings`, {
			method: 'GET',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
		});
		expect(result).toEqual(expected);
	});

	it('PUT /indexes/:name/settings sends settings body', async () => {
		const settings = {
			searchableAttributes: ['title', 'description'],
			filterableAttributes: ['category']
		};
		const expected = { updatedAt: '2026-02-25T00:00:00Z', taskID: 42 };
		const fetch = mockFetch(200, expected);
		client.setFetch(fetch);

		const result = await client.updateIndexSettings('products', settings);

		expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/settings`, {
			method: 'PUT',
			headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
			body: JSON.stringify(settings)
		});
		expect(result).toEqual(expected);
	});

	describe('rules', () => {
		it('POST /indexes/:name/rules/search sends default query payload', async () => {
			const expected: RuleSearchResponse = {
				hits: [],
				nbHits: 0,
				page: 0,
				nbPages: 0
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.searchRules('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/rules/search`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify({ query: '', page: 0, hitsPerPage: 50 })
			});
			expect(result).toEqual(expected);
		});

		it('PUT /indexes/:name/rules/:objectID sends rule body', async () => {
			const rule: Rule = {
				objectID: 'boost-shoes',
				conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
				consequence: { promote: [{ objectID: 'shoe-1', position: 0 }] },
				description: 'Boost shoes',
				enabled: true
			};
			const expected = { taskID: 7, updatedAt: '2026-02-25T01:00:00Z', id: 'boost-shoes' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.saveRule('products', 'boost-shoes', rule);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/rules/boost-shoes`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify(rule)
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/rules/:objectID returns rule', async () => {
			const expected: Rule = {
				objectID: 'boost-shoes',
				conditions: [{ pattern: 'shoes', anchoring: 'contains' }],
				consequence: { promote: [{ objectID: 'shoe-1', position: 0 }] },
				description: 'Boost shoes'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getRule('products', 'boost-shoes');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/rules/boost-shoes`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /indexes/:name/rules/:objectID sends delete request', async () => {
			const expected = { taskID: 12, deletedAt: '2026-02-25T02:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.deleteRule('products', 'boost-shoes');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/rules/boost-shoes`, {
				method: 'DELETE',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});
	});

	describe('synonyms', () => {
		it('POST /indexes/:name/synonyms/search sends default query payload', async () => {
			const expected: SynonymSearchResponse = {
				hits: [],
				nbHits: 0
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.searchSynonyms('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/synonyms/search`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify({ query: '', page: 0, hitsPerPage: 50 })
			});
			expect(result).toEqual(expected);
		});

		it('PUT /indexes/:name/synonyms/:objectID sends synonym body', async () => {
			const synonym: Synonym = {
				objectID: 'laptop-syn',
				type: 'synonym',
				synonyms: ['laptop', 'notebook', 'computer']
			};
			const expected = { taskID: 7, updatedAt: '2026-02-25T03:00:00Z', id: 'laptop-syn' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.saveSynonym('products', 'laptop-syn', synonym);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/synonyms/laptop-syn`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify(synonym)
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/synonyms/:objectID returns synonym', async () => {
			const expected: Synonym = {
				objectID: 'laptop-syn',
				type: 'onewaysynonym',
				input: 'phone',
				synonyms: ['smartphone', 'mobile']
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getSynonym('products', 'laptop-syn');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/synonyms/laptop-syn`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /indexes/:name/synonyms/:objectID sends delete request', async () => {
			const expected = { taskID: 12, deletedAt: '2026-02-25T04:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.deleteSynonym('products', 'laptop-syn');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/synonyms/laptop-syn`, {
				method: 'DELETE',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});
	});

	describe('query suggestions', () => {
		it('GET /indexes/:name/suggestions returns query suggestions config', async () => {
			const expected: QsConfig = {
				indexName: 'products',
				sourceIndices: [],
				languages: ['en'],
				exclude: [],
				allowSpecialCharacters: false,
				enablePersonalization: false
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getQsConfig('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/suggestions`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('PUT /indexes/:name/suggestions sends config body', async () => {
			const config: QsConfig = {
				indexName: 'products',
				sourceIndices: [],
				languages: ['en'],
				exclude: [],
				allowSpecialCharacters: false,
				enablePersonalization: false
			};
			const expected = { status: 'updated' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.saveQsConfig('products', config);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/suggestions`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify(config)
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /indexes/:name/suggestions sends delete request', async () => {
			const expected = { deletedAt: '2026-02-25T05:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.deleteQsConfig('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/suggestions`, {
				method: 'DELETE',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/suggestions/status returns build status', async () => {
			const expected: QsBuildStatus = {
				indexName: 'products',
				isRunning: false,
				lastBuiltAt: '2026-02-25T06:00:00Z',
				lastSuccessfulBuiltAt: '2026-02-25T06:00:00Z'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getQsStatus('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/suggestions/status`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});
	});

	describe('documents', () => {
		it('POST /indexes/:name/batch sends batch operations payload', async () => {
			const expected = { taskID: 99, objectIDs: ['obj-1', 'obj-2'] };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.addObjects('products', {
				requests: [
					{ action: 'addObject', body: { objectID: 'obj-1', title: 'First' } },
					{ action: 'addObject', body: { objectID: 'obj-2', title: 'Second' } }
				]
			});

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/batch`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify({
					requests: [
						{ action: 'addObject', body: { objectID: 'obj-1', title: 'First' } },
						{ action: 'addObject', body: { objectID: 'obj-2', title: 'Second' } }
					]
				})
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/browse sends browse payload shape', async () => {
			const expected = {
				hits: [{ objectID: 'obj-1', title: 'First' }],
				cursor: 'next-cursor',
				nbHits: 1,
				page: 0,
				nbPages: 1,
				hitsPerPage: 20,
				query: 'title:First',
				params: 'hitsPerPage=20'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.browseObjects('products', {
				cursor: 'prev-cursor',
				query: 'title:First',
				filters: 'status = published',
				hitsPerPage: 20,
				attributesToRetrieve: ['objectID', 'title'],
				params: 'hitsPerPage=20'
			});

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/browse`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify({
					cursor: 'prev-cursor',
					query: 'title:First',
					filters: 'status = published',
					hitsPerPage: 20,
					attributesToRetrieve: ['objectID', 'title'],
					params: 'hitsPerPage=20'
				})
			});
			expect(result).toEqual(expected);
		});

		it('GET /indexes/:name/objects/:object_id encodes object IDs', async () => {
			const expected = { objectID: 'sku/1', title: 'First' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getObject('products', 'sku/1');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/objects/sku%2F1`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /indexes/:name/objects/:object_id encodes object IDs', async () => {
			const expected = { taskID: 101, deletedAt: '2026-03-18T12:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.deleteObject('products', 'sku/1');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/objects/sku%2F1`, {
				method: 'DELETE',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});
	});

	describe('dictionaries', () => {
		it('GET /indexes/:name/dictionaries/languages returns available languages', async () => {
			const expected = {
				en: {
					stopwords: { nbCustomEntries: 3 },
					plurals: { nbCustomEntries: 1 },
					compounds: null
				},
				fr: {
					stopwords: { nbCustomEntries: 0 },
					plurals: null,
					compounds: null
				}
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getDictionaryLanguages('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/dictionaries/languages`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/dictionaries/:dictionary_name/search sends search body', async () => {
			const expected: DictionarySearchResponse = {
				hits: [{ objectID: 'en-the', language: 'en', word: 'the', state: 'enabled' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const body: DictionarySearchRequest = {
				query: 'the',
				language: 'en',
				page: 0,
				hitsPerPage: 20
			};
			const result = await client.searchDictionaryEntries('products', 'stopwords', body);

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/dictionaries/stopwords/search`,
				{
					method: 'POST',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
					body: JSON.stringify(body)
				}
			);
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/dictionaries/:dictionary_name/search encodes dictionary name', async () => {
			const expected: DictionarySearchResponse = { hits: [], nbHits: 0, page: 0, nbPages: 0 };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			await client.searchDictionaryEntries('products', 'compound words/v2', { query: '' });

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/dictionaries/compound%20words%2Fv2/search`,
				{
					method: 'POST',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
					body: JSON.stringify({ query: '' })
				}
			);
		});

		it('POST /indexes/:name/dictionaries/:dictionary_name/batch sends batch body', async () => {
			const expected: DictionaryBatchResponse = { taskID: 42, updatedAt: '2026-03-18T10:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const body: DictionaryBatchRequest = {
				clearExistingDictionaryEntries: false,
				requests: [
					{
						action: 'addEntry',
						body: { objectID: 'en-custom', language: 'en', word: 'custom', state: 'enabled' }
					},
					{ action: 'deleteEntry', body: { objectID: 'en-the' } }
				]
			};
			const result = await client.batchDictionaryEntries('products', 'stopwords', body);

			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/dictionaries/stopwords/batch`,
				{
					method: 'POST',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
					body: JSON.stringify(body)
				}
			);
			expect(result).toEqual(expected);
		});
	});

	describe('security sources', () => {
		it('GET /indexes/:name/security/sources returns sources list', async () => {
			const expected = {
				sources: [{ source: '192.168.1.0/24', description: 'Office network' }]
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.getSecuritySources('products');

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/security/sources`, {
				method: 'GET',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
			});
			expect(result).toEqual(expected);
		});

		it('POST /indexes/:name/security/sources sends source body', async () => {
			const body = { source: '10.0.0.0/8', description: 'VPN range' };
			const expected = { createdAt: '2026-03-19T00:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.appendSecuritySource('products', body);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/security/sources`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify(body)
			});
			expect(result).toEqual(expected);
		});

		it('DELETE /indexes/:name/security/sources/:source encodes CIDR values via pathSegment', async () => {
			const expected = { deletedAt: '2026-03-19T01:00:00Z' };
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.deleteSecuritySource('products', '192.168.1.0/24');

			// CIDR slash must be percent-encoded by pathSegment()
			expect(fetch).toHaveBeenCalledWith(
				`${BASE_URL}/indexes/products/security/sources/192.168.1.0%2F24`,
				{
					method: 'DELETE',
					headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' }
				}
			);
			expect(result).toEqual(expected);
		});
	});

	describe('index keys', () => {
		it('POST /indexes/:name/keys sends description and acl', async () => {
			const expected: FlapjackApiKey = {
				key: 'fj_search_abc123',
				createdAt: '2026-02-21T00:00:00Z'
			};
			const fetch = mockFetch(200, expected);
			client.setFetch(fetch);

			const result = await client.createIndexKey('products', 'production key', [
				'search',
				'browse'
			]);

			expect(fetch).toHaveBeenCalledWith(`${BASE_URL}/indexes/products/keys`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', Authorization: 'Bearer my-jwt-token' },
				body: JSON.stringify({ description: 'production key', acl: ['search', 'browse'] })
			});
			expect(result).toEqual(expected);
		});
	});
});
