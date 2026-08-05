import type {
	AlgoliaMigrationDestinationMode,
	MigrationPreviewArguments,
	MigrationPreviewResponse,
	SourceProvider
} from '$lib/api/types';
import { previewMigration, type MigrationCreateClient } from './migration_create_client';
import { toErrorMessage } from './migration_error_redaction';

export interface MigrationCreatePreviewState {
	result: MigrationPreviewResponse | null;
	binding: string | null;
	attemptBinding: string | null;
	error: string | null;
	activeRequest: boolean;
}

interface PreparedMigrationPreview {
	arguments: MigrationPreviewArguments;
	binding: string;
	redactions: string[];
}

interface RequestMigrationPreviewOptions {
	client: MigrationCreateClient;
	prepare: () => Promise<PreparedMigrationPreview | null>;
	currentBinding: () => string | null;
}

export function createMigrationPreviewState(): MigrationCreatePreviewState {
	return {
		result: null,
		binding: null,
		attemptBinding: null,
		error: null,
		activeRequest: false
	};
}

export function clearMigrationPreviewState(state: MigrationCreatePreviewState): void {
	clearMigrationPreviewOutcome(state);
}

function clearMigrationPreviewOutcome(state: MigrationCreatePreviewState): void {
	state.result = null;
	state.binding = null;
	state.attemptBinding = null;
	state.error = null;
}

export function markMigrationPreviewError(
	state: MigrationCreatePreviewState,
	binding: string,
	error: string
): void {
	clearMigrationPreviewOutcome(state);
	state.attemptBinding = binding;
	state.error = error;
}

export function migrationPreviewArguments({
	sourceProvider,
	sourceIdentity,
	apiKey,
	sourceName,
	targetIndex,
	mode
}: {
	sourceProvider: SourceProvider;
	sourceIdentity: string;
	apiKey: string;
	sourceName: string;
	targetIndex: string;
	mode: AlgoliaMigrationDestinationMode;
}): MigrationPreviewArguments | null {
	const common = { apiKey, sourceIndex: sourceName, targetIndex, overwrite: mode === 'replace' };
	if (sourceProvider === 'algolia') {
		return ['algolia', { ...common, appId: sourceIdentity }];
	}
	if (sourceProvider === 'meilisearch') {
		return ['meilisearch', { ...common, endpoint: sourceIdentity }];
	}
	return null;
}

export async function requestMigrationPreview(
	state: MigrationCreatePreviewState,
	options: RequestMigrationPreviewOptions
): Promise<void> {
	if (state.activeRequest) return;
	const preparationBinding = options.currentBinding();
	state.activeRequest = true;
	clearMigrationPreviewOutcome(state);
	let prepared: PreparedMigrationPreview | null = null;
	try {
		prepared = await options.prepare();
		if (prepared === null) return;
		const result = await previewMigration(options.client, ...prepared.arguments);
		if (options.currentBinding() === prepared.binding) {
			state.result = result;
			state.binding = prepared.binding;
			state.attemptBinding = prepared.binding;
		}
	} catch (error) {
		if (prepared !== null && options.currentBinding() !== prepared.binding) return;
		const attemptBinding = prepared?.binding ?? preparationBinding;
		if (attemptBinding !== null) {
			state.error = toErrorMessage(error, prepared?.redactions ?? []);
			state.attemptBinding = attemptBinding;
		}
	} finally {
		state.activeRequest = false;
	}
}
