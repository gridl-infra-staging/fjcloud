import type { ApiClient } from '$lib/api/client';
import type {
	AlgoliaDestinationEligibilityRequest,
	CreateMigrationImportJobRequest,
	ListMigrationSourceIndexesRequest,
	SourceProvider
} from '$lib/api/types';

type NeutralMigrationCreateClient = Pick<
	ApiClient,
	'listMigrationSourceIndexes' | 'checkMigrationDestinationEligibility' | 'createMigrationImportJob'
>;
type AlgoliaMigrationCreateClient = Pick<
	ApiClient,
	'listAlgoliaSourceIndexes' | 'checkAlgoliaDestinationEligibility' | 'createAlgoliaImportJob'
>;

export type MigrationCreateClient =
	| (NeutralMigrationCreateClient & Partial<AlgoliaMigrationCreateClient>)
	| (AlgoliaMigrationCreateClient & Partial<NeutralMigrationCreateClient>);

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
	return sourceProvider === 'algolia'
		? { appId: sourceIdentity, apiKey }
		: { host: sourceIdentity, apiKey };
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
