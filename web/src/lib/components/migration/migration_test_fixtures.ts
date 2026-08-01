import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';
import { expect, vi } from 'vitest';

import type {
	AlgoliaDestinationEligibilityResponse,
	AlgoliaImportJobStatus,
	AlgoliaImportWarning,
	AlgoliaIndexMetadata,
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaMigrationCapabilities,
	AlgoliaSourceListResponse,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import MigrationCreateFlow from './MigrationCreateFlow.svelte';

export type WarningFixture = AlgoliaImportWarning & { locator: string };

export type WarningGroupFixture = {
	resource: string;
	resourceLabel: string;
	accessibleName: string;
	warnings: WarningFixture[];
};

export const WARNING_GROUPS: WarningGroupFixture[] = [
	{
		resource: 'synonyms',
		resourceLabel: 'synonyms',
		accessibleName: 'synonyms compatibility warnings',
		warnings: [
			{
				resource: 'synonyms',
				code: 'unsupported_synonym_type_0',
				message: 'Change the first synonym type.',
				pageIndex: 2,
				itemIndex: 5,
				jsonPath: '$.synonyms[5]',
				locator: 'page 2, item 5, path $.synonyms[5]'
			},
			{
				resource: 'synonyms',
				code: 'unsupported_synonym_type_1',
				message: 'Change the second synonym type.',
				pageIndex: 2,
				itemIndex: 6,
				jsonPath: '$.synonyms[6]',
				locator: 'page 2, item 6, path $.synonyms[6]'
			},
			{
				resource: 'synonyms',
				code: 'unsupported_synonym_type_2',
				message: 'Change the third synonym type.',
				pageIndex: 3,
				itemIndex: 0,
				jsonPath: '$.synonyms[7]',
				locator: 'page 3, item 0, path $.synonyms[7]'
			}
		]
	},
	{
		resource: 'index-settings',
		resourceLabel: 'index settings',
		accessibleName: 'index settings compatibility warnings 1',
		warnings: [
			{
				resource: 'index-settings',
				code: 'unsupported_option_0',
				message: 'Remove the first unsupported option.',
				pageIndex: 4,
				itemIndex: 1,
				jsonPath: '$.settings[1]',
				locator: 'page 4, item 1, path $.settings[1]'
			},
			{
				resource: 'index-settings',
				code: 'unsupported_option_1',
				message: 'Remove the second unsupported option.',
				pageIndex: 4,
				itemIndex: 2,
				jsonPath: '$.settings[2]',
				locator: 'page 4, item 2, path $.settings[2]'
			}
		]
	},
	{
		resource: 'index_settings',
		resourceLabel: 'index settings',
		accessibleName: 'index settings compatibility warnings 2',
		warnings: [
			{
				resource: 'index_settings',
				code: 'unsupported_option_2',
				message: 'Remove the third unsupported option.',
				pageIndex: 5,
				itemIndex: 0,
				jsonPath: '$.settings[3]',
				locator: 'page 5, item 0, path $.settings[3]'
			},
			{
				resource: 'index_settings',
				code: 'unsupported_option_3',
				message: 'Remove the fourth unsupported option.',
				pageIndex: 5,
				itemIndex: 1,
				jsonPath: '$.settings[4]',
				locator: 'page 5, item 1, path $.settings[4]'
			}
		]
	},
	{
		resource: 'rules',
		resourceLabel: 'rules',
		accessibleName: 'rules compatibility warnings',
		warnings: [
			{
				resource: 'rules',
				code: 'unsupported_rule_0',
				message: 'Rewrite the first unsupported rule.',
				pageIndex: 6,
				itemIndex: 1,
				jsonPath: '$.rules[1]',
				locator: 'page 6, item 1, path $.rules[1]'
			},
			{
				resource: 'rules',
				code: 'unsupported_rule_1',
				message: 'Rewrite the second unsupported rule.',
				pageIndex: 6,
				itemIndex: 2,
				jsonPath: '$.rules[2]',
				locator: 'page 6, item 2, path $.rules[2]'
			},
			{
				resource: 'rules',
				code: 'unsupported_rule_2',
				message: 'Rewrite the third unsupported rule.',
				pageIndex: 7,
				itemIndex: 0,
				jsonPath: '$.rules[3]',
				locator: 'page 7, item 0, path $.rules[3]'
			}
		]
	}
];

export function publicWarnings(groups: WarningGroupFixture[]): AlgoliaImportWarning[] {
	return groups.flatMap(({ resource, warnings }) =>
		warnings.map(({ code, message, pageIndex, itemIndex, jsonPath }) => ({
			resource,
			code,
			message,
			pageIndex,
			itemIndex,
			jsonPath
		}))
	);
}

export const unavailableAvailability = {
	available: false,
	reason: 'temporarily_unavailable',
	message: 'Algolia migration is temporarily unavailable while we replace the importer.',
	capabilities: { cancel: false, resume: false, replace: false }
} satisfies AlgoliaMigrationAvailabilityResponse;

export const availableAvailability = {
	available: true,
	message: 'Algolia migration is available.',
	capabilities: { cancel: true, resume: false, replace: true }
} satisfies AlgoliaMigrationAvailabilityResponse;

// Distinctive values so a leak into markup, storage, or the URL is unambiguous
// rather than a coincidental substring match.
export const APP_ID_CANARY = 'CANARYAPPID0001';
export const API_KEY_CANARY = 'canary-secret-key-0002';

export const NO_MIGRATION_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: false,
	resume: false,
	replace: false
};

export const NO_CAPABILITIES = NO_MIGRATION_CAPABILITIES;

export const NON_TERMINAL_IMPORT_STATUSES: AlgoliaImportJobStatus[] = [
	'queued',
	'validating_source',
	'copying_configuration',
	'copying_documents',
	'verifying',
	'promoting',
	'cancelling',
	'resuming'
];

export function sourceIndex(overrides: Partial<AlgoliaIndexMetadata> = {}): AlgoliaIndexMetadata {
	return {
		name: 'source_products',
		entries: 1234,
		dataSize: 2048,
		fileSize: 4096,
		updatedAt: '2026-07-18T10:00:00Z',
		lastBuildTimeS: 17,
		pendingTask: false,
		primary: null,
		replicas: [],
		...overrides
	};
}

export function listResponse(
	items: AlgoliaIndexMetadata[],
	nextCursor: string | null = null
): AlgoliaSourceListResponse {
	return { items, nextCursor };
}

export function importJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: 'job_123',
		status: 'queued',
		mode: 'create',
		sourceProvider: 'algolia',
		destination: { kind: 'create', target: 'source_products', region: 'us-east-1' },
		source: { name: 'source_products' },
		summary: {
			documentsExpected: 0,
			documentsImported: 0,
			documentsRejected: 0,
			settingsApplied: 0,
			settingsUnsupported: 0,
			synonymsExpected: 0,
			synonymsImported: 0,
			synonymsRejected: 0,
			rulesExpected: 0,
			rulesImported: 0,
			rulesRejected: 0
		},
		terminalOutcomeObserved: false,
		warnings: [],
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'not_started',
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:00:00Z',
		...overrides
	};
}

export function publicImportJob(
	overrides: Partial<PublicAlgoliaImportJob> = {}
): PublicAlgoliaImportJob {
	const status = overrides.status ?? 'completed';
	return {
		id: 'job_123',
		status,
		mode: 'create',
		sourceProvider: 'algolia',
		destination: {
			kind: 'create',
			target: 'products migrated/2026',
			region: 'us-east-1'
		},
		source: {
			name: 'products'
		},
		summary: {
			documentsExpected: 17,
			documentsImported: 13,
			documentsRejected: 4,
			settingsApplied: 2,
			settingsUnsupported: 1,
			synonymsExpected: 5,
			synonymsImported: 3,
			synonymsRejected: 2,
			rulesExpected: 7,
			rulesImported: 6,
			rulesRejected: 1
		},
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'promoted',
		terminalOutcomeObserved: status === 'completed' || status === 'completed_with_warnings',
		warnings: [],
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	};
}

export const ELIGIBLE_AWS_PROVIDER = {
	phase: 'provider',
	mode: 'create',
	provider: 'aws',
	target: {
		kind: 'create',
		region: 'us-east-1',
		name: 'products_migration'
	},
	eligibilityToken: 'provider-eligibility-token',
	expiresAt: '2099-07-18T10:15:00Z'
} as const;

export const ELIGIBLE_AWS_REPLACE_PROVIDER = {
	phase: 'provider',
	mode: 'replace',
	provider: 'aws',
	target: {
		kind: 'replace',
		region: 'us-west-2',
		name: 'existing_products'
	},
	eligibilityToken: 'replace-provider-eligibility-token',
	expiresAt: '2099-07-18T10:15:00Z'
} as const;

export type MigrationFlowClient = ComponentProps<typeof MigrationCreateFlow>['client'];

export function migrationClient(listAlgoliaSourceIndexes = vi.fn()): MigrationFlowClient {
	return {
		listAlgoliaSourceIndexes,
		checkAlgoliaDestinationEligibility: vi.fn(),
		createAlgoliaImportJob: vi.fn()
	};
}

export function renderFlow(
	listAlgoliaSourceIndexes = vi.fn(),
	capabilities: AlgoliaMigrationCapabilities | undefined = undefined,
	providerEligibility: AlgoliaDestinationEligibilityResponse = ELIGIBLE_AWS_PROVIDER
) {
	const result = render(MigrationCreateFlow, {
		client: migrationClient(listAlgoliaSourceIndexes),
		providerEligibility,
		capabilities
	});
	return { ...result, listAlgoliaSourceIndexes };
}

export async function connect(
	listAlgoliaSourceIndexes: ReturnType<typeof vi.fn>,
	appId = APP_ID_CANARY,
	apiKey = API_KEY_CANARY,
	waitForCompletion = true
) {
	await fireEvent.input(screen.getByLabelText(/algolia application id/i), {
		target: { value: appId }
	});
	await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
		target: { value: apiKey }
	});
	await fireEvent.click(screen.getByRole('button', { name: /connect to algolia/i }));
	await waitFor(() => expect(listAlgoliaSourceIndexes).toHaveBeenCalled());
	if (waitForCompletion) {
		await waitForDiscoveryToSettle();
	}
	return listAlgoliaSourceIndexes;
}

export async function waitForDiscoveryToSettle() {
	await waitFor(() =>
		expect(screen.queryByTestId('migration-source-loading')).not.toBeInTheDocument()
	);
}
