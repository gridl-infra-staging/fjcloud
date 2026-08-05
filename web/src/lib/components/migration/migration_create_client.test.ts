import { describe, expect, it, vi } from 'vitest';
import type { MigrationPreviewResponse } from '$lib/api/types';
import { previewMigration, type MigrationCreateClient } from './migration_create_client';

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
