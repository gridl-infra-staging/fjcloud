import { describe, expect, it, vi } from 'vitest';
import type { MigrationPreviewResponse } from '$lib/api/types';
import { createAuthenticatedClient, mockFetch } from '$lib/api/client.test.shared';
import {
	HOSTED_SOURCE_INDEXES_WIRE_RESPONSE,
	HOSTED_SOURCE_INDEX_EXPECTED_PAIRS,
	neutralSourceListRequest
} from '$lib/api/client_migration_test_fixtures';
import {
	listMigrationSources,
	migrationSourceCredentials,
	previewMigration,
	type MigrationCreateClient
} from './migration_create_client';
import * as migrationCreateClientModule from './migration_create_client';

const PREVIEW_RESPONSE: MigrationPreviewResponse = {
	sourceCounts: { indexes: 1, records: 2 },
	report: {
		summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
		entries: [],
		reportDigest: 'sha256:client-preview'
	}
};

function neutralCreateClient(
	previewMigrationImport: MigrationCreateClient['previewMigrationImport']
): MigrationCreateClient {
	return {
		listMigrationSourceIndexes: vi.fn(),
		checkMigrationDestinationEligibility: vi.fn(),
		createMigrationImportJob: vi.fn(),
		previewMigrationImport
	} as MigrationCreateClient;
}

function sourceIndexPairs(response: Awaited<ReturnType<typeof listMigrationSources>>) {
	return response.items?.map(({ name, entries }) => ({ name, entries }));
}

describe('listMigrationSources', () => {
	it('delegates Meilisearch source-index normalization to the real migration client', async () => {
		const client = createAuthenticatedClient();
		const fetch = mockFetch(200, HOSTED_SOURCE_INDEXES_WIRE_RESPONSE);
		client.setFetch(fetch);
		const request = neutralSourceListRequest('meilisearch');

		const result = await listMigrationSources(client, 'meilisearch', request);

		expect(sourceIndexPairs(result)).toEqual(HOSTED_SOURCE_INDEX_EXPECTED_PAIRS);
	});
});

describe('migrationSourceCredentials', () => {
	it.each([
		{
			sourceProvider: 'algolia',
			sourceIdentity: 'ALGOLIA_APP',
			expected: { appId: 'ALGOLIA_APP', apiKey: 'source-api-key' }
		},
		{
			sourceProvider: 'meilisearch',
			sourceIdentity: 'https://meilisearch.example.test',
			expected: { endpoint: 'https://meilisearch.example.test', apiKey: 'source-api-key' }
		},
		{
			sourceProvider: 'typesense',
			sourceIdentity: 'https://typesense.example.test',
			expected: { node: 'https://typesense.example.test', apiKey: 'source-api-key' }
		}
	] as const)(
		'maps $sourceProvider identity to its producer-native request field',
		({ sourceProvider, sourceIdentity, expected }) => {
			const result = migrationSourceCredentials(sourceProvider, sourceIdentity, 'source-api-key');

			expect(result).toEqual(expected);
			expect(result).not.toHaveProperty('host');
		}
	);
});

describe('migrationSourcePageRequest', () => {
	const migrationSourcePageRequest = Reflect.get(
		migrationCreateClientModule,
		'migrationSourcePageRequest'
	) as
		| ((
				sourceProvider: 'algolia' | 'meilisearch' | 'typesense',
				sourceIdentity: string,
				apiKey: string,
				cursor: string | null
		  ) => unknown)
		| undefined;

	it('keeps Algolia cursor pagination in its provider request', () => {
		expect(migrationSourcePageRequest).toBeTypeOf('function');
		expect(
			migrationSourcePageRequest?.('algolia', 'ALGOLIA_APP', 'source-api-key', 'algolia/cursor')
		).toEqual({ appId: 'ALGOLIA_APP', apiKey: 'source-api-key', cursor: 'algolia/cursor' });
	});

	it.each([
		{
			sourceProvider: 'meilisearch' as const,
			sourceIdentity: 'https://meilisearch.example.test',
			expected: {
				endpoint: 'https://meilisearch.example.test',
				apiKey: 'source-api-key',
				offset: 25,
				limit: 100
			}
		},
		{
			sourceProvider: 'typesense' as const,
			sourceIdentity: 'https://typesense.example.test',
			expected: {
				node: 'https://typesense.example.test',
				apiKey: 'source-api-key',
				offset: 25,
				limit: 100
			}
		}
	])(
		'converts canonical cursor to numeric $sourceProvider offset pagination',
		({ sourceProvider, sourceIdentity, expected }) => {
			expect(migrationSourcePageRequest).toBeTypeOf('function');
			const result = migrationSourcePageRequest?.(
				sourceProvider,
				sourceIdentity,
				'source-api-key',
				'25'
			);

			expect(result).toEqual(expected);
			expect(result).not.toHaveProperty('cursor');
		}
	);
});

describe('previewMigration', () => {
	it('forwards the exact algolia provider and request to the client preview method', async () => {
		const previewMigrationImport = vi
			.fn()
			.mockResolvedValue(PREVIEW_RESPONSE) as MigrationCreateClient['previewMigrationImport'];
		const client: MigrationCreateClient = neutralCreateClient(previewMigrationImport);
		const request = {
			appId: 'app-id',
			apiKey: 'api-key',
			sourceIndex: 'source_products',
			targetIndex: 'destination_products',
			overwrite: true
		};

		const result = await previewMigration(client, 'algolia', request);

		expect(previewMigrationImport).toHaveBeenCalledOnce();
		expect(previewMigrationImport).toHaveBeenCalledWith('algolia', request);
		expect(result).toBe(PREVIEW_RESPONSE);
	});

	it('forwards the exact meilisearch provider and request to the client preview method', async () => {
		const previewMigrationImport = vi
			.fn()
			.mockResolvedValue(PREVIEW_RESPONSE) as MigrationCreateClient['previewMigrationImport'];
		const client: MigrationCreateClient = neutralCreateClient(previewMigrationImport);
		const request = {
			endpoint: 'https://meili.example.com',
			apiKey: 'api-key',
			sourceIndex: 'source_products',
			targetIndex: 'destination_products',
			overwrite: false
		};

		const result = await previewMigration(client, 'meilisearch', request);

		expect(previewMigrationImport).toHaveBeenCalledOnce();
		expect(previewMigrationImport).toHaveBeenCalledWith('meilisearch', request);
		expect(result).toBe(PREVIEW_RESPONSE);
	});

	it('requires preview capability on every create client at compile time', () => {
		const algoliaOnlyClient = {
			listAlgoliaSourceIndexes: vi.fn(),
			checkAlgoliaDestinationEligibility: vi.fn(),
			createAlgoliaImportJob: vi.fn()
		};
		// @ts-expect-error previewMigrationImport is a required create-flow capability
		const client: MigrationCreateClient = algoliaOnlyClient;
		expect(client).toBeDefined();
	});
});
