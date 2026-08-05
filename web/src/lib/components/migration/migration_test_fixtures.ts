import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import type { ComponentProps } from 'svelte';
import { expect, vi } from 'vitest';

import type {
	AlgoliaDestinationEligibilityResponse,
	AlgoliaImportJobStatus,
	AlgoliaIndexMetadata,
	AlgoliaMigrationCapabilities,
	AlgoliaSourceListResponse,
	MigrationPreviewResponse,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import MigrationCreateFlow from './MigrationCreateFlow.svelte';
import type { AlgoliaImportCompatibilityWarningPresentation } from './job_presentation';
import type { WarningGroupFixture } from './migration_fixtures_data';
export {
	availableAvailability,
	publicWarnings,
	unavailableAvailability,
	WARNING_GROUPS,
	type WarningFixture,
	type WarningGroupFixture
} from './migration_fixtures_data';

/**
 * Builds the shared warning presentation directly from group fixtures, so the
 * renderer can be exercised without routing through a retained job. Every
 * producer of that presentation type must render identically through it.
 */
export function warningGroupPresentation(
	groups: WarningGroupFixture[],
	summary: string
): AlgoliaImportCompatibilityWarningPresentation {
	return {
		summary,
		groups: groups.map(({ resource, resourceLabel, warnings }) => ({
			resource,
			resourceLabel,
			warnings: warnings.map(({ code, message, locator }) => ({ code, message, locator }))
		}))
	};
}

// Distinctive values so a leak into markup, storage, or the URL is unambiguous
// rather than a coincidental substring match.
export const APP_ID_CANARY = 'CANARYAPPID0001';
export const API_KEY_CANARY = 'canary-secret-key-0002';

export const NO_MIGRATION_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: false,
	resume: false,
	replace: false,
	preview: false,
	verify: false
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

export function previewResponse(
	overrides: Partial<MigrationPreviewResponse> = {}
): MigrationPreviewResponse {
	return {
		sourceCounts: { indexes: 3, records: 42 },
		report: {
			summary: { totalEntries: 2, hardRejections: 1, warnings: 1, scopeGaps: 0 },
			entries: [
				{
					severity: 'Warning',
					code: 'UnsupportedSourceField',
					resource: 'Settings',
					pageIndex: null,
					itemIndex: 0,
					jsonPath: '$.settings.attributesForFaceting[0]'
				},
				{
					severity: 'HardRejection',
					code: 'MalformedDocumentPayload',
					resource: 'Document',
					pageIndex: 1,
					itemIndex: 7,
					jsonPath: '$.hits[7]'
				}
			],
			reportDigest: 'sha256:flow-preview-report'
		},
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

export const TARGET_ELIGIBILITY = {
	phase: 'target',
	mode: 'create',
	provider: 'aws',
	target: {
		kind: 'create',
		region: 'us-east-1',
		name: 'source_products'
	},
	eligibilityToken: 'target-eligibility-token',
	expiresAt: '2099-07-18T10:20:00Z'
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

export const REPLACE_TARGET_ELIGIBILITY = {
	phase: 'target',
	mode: 'replace',
	provider: 'aws',
	target: { kind: 'replace', region: 'us-west-2', name: 'existing_products' },
	eligibilityToken: 'replace-target-eligibility-token',
	expiresAt: '2099-07-18T10:20:00Z'
} as const;

export const REPLACE_CAPABILITY = {
	cancel: false,
	resume: false,
	replace: true,
	preview: false,
	verify: false
} as const;

export type MigrationFlowClient = ComponentProps<typeof MigrationCreateFlow>['client'];

export function migrationClient(listAlgoliaSourceIndexes = vi.fn()): MigrationFlowClient {
	return {
		listAlgoliaSourceIndexes,
		checkAlgoliaDestinationEligibility: vi.fn(),
		previewMigrationImport: vi.fn().mockResolvedValue(previewResponse()),
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
