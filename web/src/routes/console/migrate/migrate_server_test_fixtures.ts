import { vi } from 'vitest';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

export const getAlgoliaMigrationAvailabilityMock = vi.fn();
export const getMigrationAvailabilityMock = vi.fn();
export const checkAlgoliaDestinationEligibilityMock = vi.fn();
export const listAlgoliaSourceIndexesMock = vi.fn();
export const createAlgoliaImportJobMock = vi.fn();
export const listAlgoliaImportJobsMock = vi.fn();
export const checkMigrationDestinationEligibilityMock = vi.fn();
export const listMigrationSourceIndexesMock = vi.fn();
export const createMigrationImportJobMock = vi.fn();
export const previewMigrationImportMock = vi.fn();
export const listMigrationImportJobsMock = vi.fn();
export const CLOSED_SOURCE_PROVIDERS = ['algolia', 'meilisearch', 'typesense'] as const;
export const HOSTED_SOURCE_PROVIDERS = ['meilisearch', 'typesense'] as const;
export const INVALID_SOURCE_PROVIDERS = ['elastic', '../typesense'] as const;
export type SourceProvider = (typeof CLOSED_SOURCE_PROVIDERS)[number];

export function createMigrationApiClientMock() {
	return {
		getAlgoliaMigrationAvailability: getAlgoliaMigrationAvailabilityMock,
		getMigrationAvailability: getMigrationAvailabilityMock,
		checkAlgoliaDestinationEligibility: checkAlgoliaDestinationEligibilityMock,
		listAlgoliaSourceIndexes: listAlgoliaSourceIndexesMock,
		createAlgoliaImportJob: createAlgoliaImportJobMock,
		listAlgoliaImportJobs: listAlgoliaImportJobsMock,
		checkMigrationDestinationEligibility: checkMigrationDestinationEligibilityMock,
		listMigrationSourceIndexes: listMigrationSourceIndexesMock,
		createMigrationImportJob: createMigrationImportJobMock,
		previewMigrationImport: previewMigrationImportMock,
		listMigrationImportJobs: listMigrationImportJobsMock
	};
}

export const routeOwnerFiles = ['+page.svelte', '+page.server.ts', '+server.ts'];

export function findDynamicRouteOwners(
	dir: string,
	prefix: string,
	insideDynamicSegment = false,
	isRoot = true
): string[] {
	const owners: string[] = [];
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch (error) {
		// The root call must fail loudly: if src/routes/console/migrate itself is
		// misresolved or unreadable, swallowing the error would let the guard pass
		// vacuously as []. Only tolerate read failures on recursed child paths
		// (e.g. a directory that vanished mid-walk), which cannot mask a served
		// dynamic route owner.
		if (isRoot) throw error;
		return owners;
	}
	if (insideDynamicSegment) {
		for (const ownerFile of routeOwnerFiles) {
			if (existsSync(join(dir, ownerFile))) {
				owners.push(`${prefix}/${ownerFile}`);
			}
		}
	}
	for (const entry of entries) {
		if (!entry.isDirectory()) continue;
		const childPath = join(dir, entry.name);
		const childPrefix = prefix ? `${prefix}/${entry.name}` : entry.name;
		const childIsDynamic = insideDynamicSegment || /^\[.+\]$/.test(entry.name);
		owners.push(...findDynamicRouteOwners(childPath, childPrefix, childIsDynamic, false));
	}
	return owners;
}

export function actionRequest(fields: Record<string, string>): Request {
	const formData = new FormData();
	for (const [key, value] of Object.entries(fields)) {
		formData.set(key, value);
	}
	return new Request('http://localhost/console/migrate', {
		method: 'POST',
		body: formData
	});
}

export function payloadRequest(
	payload: unknown,
	extraFields: Record<string, string> = {}
): Request {
	return actionRequest({
		payload: JSON.stringify(payload),
		...extraFields
	});
}

export function sourceListPayload(sourceProvider: SourceProvider) {
	if (sourceProvider === 'algolia') {
		return {
			source_provider: 'algolia',
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			cursor: 'algolia_cursor'
		};
	}
	return {
		source_provider: sourceProvider,
		...(sourceProvider === 'meilisearch'
			? { endpoint: `https://${sourceProvider}.example.test` }
			: { node: `https://${sourceProvider}.example.test` }),
		apiKey: `${sourceProvider}_api_key_canary`
	};
}

export function createJobPayload(sourceProvider: SourceProvider) {
	if (sourceProvider === 'algolia') {
		return {
			source_provider: 'algolia',
			mode: 'create',
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			sourceName: 'algolia_products',
			target: { eligibilityToken: 'algolia-target-token' }
		};
	}
	return {
		source_provider: sourceProvider,
		mode: 'create',
		...(sourceProvider === 'meilisearch'
			? { endpoint: `https://${sourceProvider}.example.test` }
			: { node: `https://${sourceProvider}.example.test` }),
		apiKey: `${sourceProvider}_api_key_canary`,
		sourceIndex: `${sourceProvider}_products`,
		target: { eligibilityToken: `${sourceProvider}-target-token` }
	};
}

export function previewPayload(sourceProvider: 'algolia' | 'meilisearch') {
	if (sourceProvider === 'algolia') {
		return {
			source_provider: 'algolia',
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			sourceIndex: 'algolia_products',
			targetIndex: 'algolia_target',
			overwrite: false
		};
	}
	return {
		source_provider: 'meilisearch',
		endpoint: 'https://meilisearch.example.test',
		apiKey: 'meilisearch_api_key_canary',
		sourceIndex: 'configured_pk',
		targetIndex: 'configured_pk',
		overwrite: false
	};
}

export function forwardedSourceCredentials(payload: ReturnType<typeof sourceListPayload>) {
	const credentials = { ...payload };
	Reflect.deleteProperty(credentials, 'source_provider');
	return credentials;
}

export function forwardedCreateBody(payload: ReturnType<typeof createJobPayload>) {
	const body = { ...payload };
	Reflect.deleteProperty(body, 'source_provider');
	return body;
}
export function resetMigrateServerMocks(): void {
	vi.clearAllMocks();
	getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
		available: false,
		reason: 'temporarily_unavailable',
		message: 'Algolia migration is temporarily unavailable while we replace the importer.',
		capabilities: { cancel: false, resume: false, replace: false, preview: false, verify: false }
	});
	getMigrationAvailabilityMock.mockResolvedValue({
		available: false,
		reason: 'temporarily_unavailable',
		message: 'Algolia migration is temporarily unavailable while we replace the importer.',
		capabilities: { cancel: false, resume: false, replace: false, preview: false, verify: false }
	});
	checkAlgoliaDestinationEligibilityMock.mockResolvedValue({
		phase: 'provider',
		mode: 'create',
		provider: 'aws',
		target: { kind: 'create', region: 'us-east-1' },
		eligibilityToken: 'provider-token',
		expiresAt: '2099-07-18T10:15:00Z'
	});
	listAlgoliaSourceIndexesMock.mockResolvedValue({ items: [], nextCursor: null });
	createAlgoliaImportJobMock.mockResolvedValue({ id: 'job_123' });
	listAlgoliaImportJobsMock.mockResolvedValue({ jobs: [], nextCursor: null });
	checkMigrationDestinationEligibilityMock.mockResolvedValue({
		phase: 'provider',
		mode: 'create',
		provider: 'aws',
		target: { kind: 'create', region: 'us-east-1' },
		eligibilityToken: 'provider-token',
		expiresAt: '2099-07-18T10:15:00Z'
	});
	listMigrationSourceIndexesMock.mockResolvedValue({ items: [], nextCursor: null });
	createMigrationImportJobMock.mockResolvedValue({ id: 'job_123' });
	previewMigrationImportMock.mockResolvedValue({
		sourceCounts: { indexes: 1, records: 4 },
		report: {
			summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
			entries: [],
			reportDigest: 'sha256:test-preview'
		}
	});
	listMigrationImportJobsMock.mockResolvedValue({ jobs: [], nextCursor: null });
}
