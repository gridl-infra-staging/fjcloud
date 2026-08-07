import { describe, expect, it, vi } from 'vitest';
import type { MigrationPreviewResponse } from '$lib/api/types';
import {
	migrationCreateRequest,
	migrationSourceCredentials,
	migrationSourceRevision,
	previewMigration,
	type MigrationCreateClient
} from './migration_create_client';

const HOSTED_SOURCE = {
	name: 'configured_pk',
	entries: 3,
	dataSize: 30,
	fileSize: 40,
	updatedAt: '2026-08-05T12:00:00Z',
	lastBuildTimeS: 0,
	pendingTask: false,
	primary: 'sku',
	replicas: []
};

const HOSTED_SOURCE_WITH_REVISION = {
	...HOSTED_SOURCE,
	updatedAt: '',
	revision: 'sha256:typesense-content-revision'
};

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

describe('migrationSourceCredentials', () => {
	it.each([
		{
			sourceProvider: 'algolia',
			expected: { appId: 'ALGOLIA_APP', apiKey: 'source-api-key' }
		},
		{
			sourceProvider: 'meilisearch',
			expected: { endpoint: 'https://meilisearch.example.test', apiKey: 'source-api-key' }
		},
		{
			sourceProvider: 'typesense',
			expected: { node: 'https://typesense.example.test', apiKey: 'source-api-key' }
		}
	] as const)(
		'maps $sourceProvider identity to the provider API field',
		({ sourceProvider, expected }) => {
			const sourceIdentities = {
				algolia: 'ALGOLIA_APP',
				meilisearch: 'https://meilisearch.example.test',
				typesense: 'https://typesense.example.test'
			};

			expect(
				migrationSourceCredentials(
					sourceProvider,
					sourceIdentities[sourceProvider],
					'source-api-key'
				)
			).toEqual(expected);
		}
	);

	// Explicit red phase for the shipped hosted contract: the credential builder must
	// never re-emit the stale hosted discovery union `{ host, apiKey }`. Hosted providers
	// carry identity in `endpoint`/`node`, so `host` must be absent for every provider.
	it.each(['meilisearch', 'typesense', 'algolia'] as const)(
		'%s discovery credentials never emit the stale `host` union field',
		(sourceProvider) => {
			const credentials = migrationSourceCredentials(
				sourceProvider,
				'source-identity.example.test',
				'source-api-key'
			);
			expect(credentials).not.toHaveProperty('host');
			expect(credentials).not.toHaveProperty('sourceName');
		}
	);
});

describe('migration create request', () => {
	it('pins the producer-native hosted revision and omits it for Algolia', () => {
		expect(migrationSourceRevision('meilisearch', HOSTED_SOURCE)).toEqual({
			documentCount: 3,
			updatedAt: '2026-08-05T12:00:00Z'
		});
		expect(migrationSourceRevision('typesense', HOSTED_SOURCE_WITH_REVISION)).toEqual({
			documentCount: 3,
			revision: 'sha256:typesense-content-revision'
		});
		expect(migrationSourceRevision('algolia', HOSTED_SOURCE)).toBeUndefined();
	});

	it.each([
		{
			sourceProvider: 'algolia',
			sourceIdentity: 'ALGOLIA_APP',
			expected: {
				mode: 'create',
				appId: 'ALGOLIA_APP',
				apiKey: 'source-key',
				sourceName: 'configured_pk',
				target: { eligibilityToken: 'eligibility-token' }
			}
		},
		{
			sourceProvider: 'meilisearch',
			sourceIdentity: 'https://meili.example.test',
			expected: {
				mode: 'create',
				endpoint: 'https://meili.example.test',
				apiKey: 'source-key',
				sourceIndex: 'configured_pk',
				sourceRevision: { documentCount: 3, updatedAt: '2026-08-05T12:00:00Z' },
				target: { eligibilityToken: 'eligibility-token' }
			}
		},
		{
			sourceProvider: 'typesense',
			sourceIdentity: 'https://typesense.example.test',
			expected: {
				mode: 'create',
				node: 'https://typesense.example.test',
				apiKey: 'source-key',
				sourceIndex: 'configured_pk',
				sourceRevision: { documentCount: 3, updatedAt: '2026-08-05T12:00:00Z' },
				target: { eligibilityToken: 'eligibility-token' }
			}
		}
	] as const)(
		'builds the exact $sourceProvider create body',
		({ sourceProvider, sourceIdentity, expected }) => {
			expect(
				migrationCreateRequest({
					sourceProvider,
					mode: 'create',
					sourceIdentity,
					apiKey: 'source-key',
					sourceName: 'configured_pk',
					selectedSource: HOSTED_SOURCE,
					eligibilityToken: 'eligibility-token'
				})
			).toEqual(expected);
		}
	);
});
