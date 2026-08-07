import type { ApiClient } from '$lib/api/client';
import type {
	AlgoliaDestinationEligibilityRequest,
	CreateMigrationImportJobRequest,
	ListMigrationSourceIndexesRequest,
	MigrationPreviewArguments,
	MigrationPreviewResponse,
	SourceProvider
} from '$lib/api/types';

type NeutralMigrationCreateClient = Pick<
	ApiClient,
	| 'listMigrationSourceIndexes'
	| 'checkMigrationDestinationEligibility'
	| 'createMigrationImportJob'
	| 'previewMigrationImport'
>;
type AlgoliaMigrationCreateClient = Pick<
	ApiClient,
	'listAlgoliaSourceIndexes' | 'checkAlgoliaDestinationEligibility' | 'createAlgoliaImportJob'
>;

export type MigrationCreateClient =
	| (NeutralMigrationCreateClient & Partial<AlgoliaMigrationCreateClient>)
	| (AlgoliaMigrationCreateClient &
			Pick<ApiClient, 'previewMigrationImport'> &
			Partial<NeutralMigrationCreateClient>);

const HOSTED_SOURCE_DISCOVERY_PAGE_SIZE = 100;

export async function sourceCredentialFingerprint(value: string): Promise<string> {
	const digest = await globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
	return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function usesNeutralMigrationClient(
	client: MigrationCreateClient
): client is NeutralMigrationCreateClient {
	return typeof client.listMigrationSourceIndexes === 'function';
}

export function migrationSourceCredentials(
	sourceProvider: SourceProvider,
	sourceIdentity: string,
	apiKey: string
): ListMigrationSourceIndexesRequest {
	if (sourceProvider === 'algolia') {
		return { appId: sourceIdentity, apiKey };
	}
	if (sourceProvider === 'meilisearch') {
		return { endpoint: sourceIdentity, apiKey };
	}
	return { node: sourceIdentity, apiKey };
}

export function migrationSourcePageRequest(
	sourceProvider: SourceProvider,
	sourceIdentity: string,
	apiKey: string,
	cursor: string | null
): ListMigrationSourceIndexesRequest {
	const credentials = migrationSourceCredentials(sourceProvider, sourceIdentity, apiKey);
	if (cursor === null) {
		return credentials;
	}
	if ('appId' in credentials) {
		return { ...credentials, cursor };
	}
	return {
		...credentials,
		offset: Number.parseInt(cursor, 10),
		limit: HOSTED_SOURCE_DISCOVERY_PAGE_SIZE
	};
}

export async function listMigrationSources(
	client: MigrationCreateClient,
	sourceProvider: SourceProvider,
	request: ListMigrationSourceIndexesRequest
) {
	if (usesNeutralMigrationClient(client)) {
		return client.listMigrationSourceIndexes(sourceProvider, request);
	}
	if (sourceProvider === 'algolia' && 'appId' in request) {
		return client.listAlgoliaSourceIndexes(request);
	}
	throw new Error('A neutral migration client is required for this source provider.');
}

export async function checkMigrationDestination(
	client: MigrationCreateClient,
	sourceProvider: SourceProvider,
	request: AlgoliaDestinationEligibilityRequest
) {
	if (usesNeutralMigrationClient(client)) {
		return client.checkMigrationDestinationEligibility(sourceProvider, request);
	}
	if (sourceProvider === 'algolia') {
		return client.checkAlgoliaDestinationEligibility(request);
	}
	throw new Error('A neutral migration client is required for this source provider.');
}

export async function createMigrationJob(
	client: MigrationCreateClient,
	sourceProvider: SourceProvider,
	request: CreateMigrationImportJobRequest,
	idempotencyKey: string
) {
	if (usesNeutralMigrationClient(client)) {
		return client.createMigrationImportJob(sourceProvider, request, idempotencyKey);
	}
	if (sourceProvider === 'algolia' && 'appId' in request) {
		return client.createAlgoliaImportJob(request, idempotencyKey);
	}
	throw new Error('A neutral migration client is required for this source provider.');
}

export async function previewMigration(
	client: MigrationCreateClient,
	...previewArguments: MigrationPreviewArguments
): Promise<MigrationPreviewResponse> {
	return client.previewMigrationImport(...previewArguments);
}
