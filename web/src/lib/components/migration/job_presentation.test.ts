import { describe, expect, it } from 'vitest';

import type {
	AlgoliaImportJobStatus,
	AlgoliaMigrationCapabilities,
	PublicAlgoliaImportError,
	PublicAlgoliaImportJob
} from '$lib/api/types';
import {
	algoliaImportSummaryRows,
	describeAlgoliaImportAdmission,
	describeAlgoliaImportError,
	describeAlgoliaImportJobActions,
	describeAlgoliaImportPublicationDisposition,
	describeAlgoliaImportStatus
} from './job_presentation';

const ALL_STATUSES: Array<{
	status: AlgoliaImportJobStatus;
	label: string;
	phase: string;
	running: boolean;
	terminal: boolean;
}> = [
	{ status: 'queued', label: 'Queued', phase: 'Waiting to start', running: true, terminal: false },
	{
		status: 'validating_source',
		label: 'Validating source',
		phase: 'Checking source access',
		running: true,
		terminal: false
	},
	{
		status: 'copying_configuration',
		label: 'Copying configuration',
		phase: 'Copying settings, synonyms, and rules',
		running: true,
		terminal: false
	},
	{
		status: 'copying_documents',
		label: 'Copying documents',
		phase: 'Copying records',
		running: true,
		terminal: false
	},
	{
		status: 'verifying',
		label: 'Verifying',
		phase: 'Verifying imported data',
		running: true,
		terminal: false
	},
	{
		status: 'promoting',
		label: 'Promoting',
		phase: 'Promoting destination',
		running: true,
		terminal: false
	},
	{
		status: 'cancelling',
		label: 'Cancelling',
		phase: 'Stopping import',
		running: true,
		terminal: false
	},
	{
		status: 'resuming',
		label: 'Resuming',
		phase: 'Preparing resume',
		running: true,
		terminal: false
	},
	{
		status: 'cancelled',
		label: 'Cancelled',
		phase: 'Stopped before completion',
		running: false,
		terminal: true
	},
	{
		status: 'completed',
		label: 'Completed',
		phase: 'Import complete',
		running: false,
		terminal: true
	},
	{
		status: 'completed_with_warnings',
		label: 'Completed with warnings',
		phase: 'Import complete with warnings',
		running: false,
		terminal: true
	},
	{ status: 'failed', label: 'Failed', phase: 'Import failed', running: false, terminal: true },
	{
		status: 'interrupted',
		label: 'Interrupted',
		phase: 'Import interrupted',
		running: false,
		terminal: true
	}
];

function publicJob(overrides: Partial<PublicAlgoliaImportJob> = {}): PublicAlgoliaImportJob {
	return {
		id: 'job_123',
		status: 'completed',
		mode: 'create',
		destination: {
			kind: 'create',
			target: 'products_migrated',
			region: 'us-east-1'
		},
		source: {
			appId: 'ALGOLIA_APP',
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
		warnings: { ignored: 'must not be stringified' },
		error: null,
		cancelRequestedAt: null,
		resumeProvenance: null,
		resumeDeadline: null,
		resumable: false,
		resumeCount: 0,
		publicationDisposition: 'promoted',
		createdAt: '2026-07-18T10:00:00Z',
		updatedAt: '2026-07-18T10:05:00Z',
		...overrides
	};
}

const NO_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: false,
	resume: false,
	replace: false
};

const ERROR_PRESENTATIONS: Array<[PublicAlgoliaImportError['code'], string]> = [
	['invalid_credentials', 'Algolia credentials were rejected. Reconnect with a valid key.'],
	[
		'missing_source_permission',
		'The Algolia key does not have permission to read the source index.'
	],
	['source_not_found', 'The source index could not be found.'],
	['source_catalog_too_large', 'The Algolia source catalog is too large to import.'],
	['destination_conflict', 'The destination index conflicts with another import.'],
	['quota_exceeded', 'The import exceeds the destination quota.'],
	['source_too_large', 'The source index is too large to import.'],
	['insufficient_engine_storage', 'The destination does not have enough storage for this import.'],
	['destination_changed', 'The destination changed while the import was running.'],
	['source_changed', 'The source changed while the import was running.'],
	['incompatible_data', 'Some source data is not compatible with the destination.'],
	['engine_upgrade_required', 'The destination must be upgraded before this import can continue.'],
	[
		'migration_ha_not_supported',
		'This import is not supported for high-availability destinations.'
	],
	['migration_provider_unsupported', 'This destination provider does not support Algolia imports.'],
	['backend_unavailable', 'The migration service is temporarily unavailable.'],
	['interrupted', 'The import was interrupted before it completed.'],
	['cancel_not_permitted', 'This import can no longer be cancelled.'],
	['not_resumable', 'This import cannot be resumed. Start a new import instead.'],
	['internal', 'The import stopped because of an internal error.']
];

describe('Algolia import job presentation seam', () => {
	it.each(ALL_STATUSES)('labels $status without deriving a parallel lifecycle', (expected) => {
		expect(describeAlgoliaImportStatus(expected.status)).toEqual(expected);
	});

	it('summarizes the DTO counts directly instead of deriving fake percentages', () => {
		expect(algoliaImportSummaryRows(publicJob())).toEqual([
			{ label: 'Documents', imported: 13, expected: 17, rejected: 4 },
			{ label: 'Settings', imported: 2, expected: 3, rejected: 1 },
			{ label: 'Synonyms', imported: 3, expected: 5, rejected: 2 },
			{ label: 'Rules', imported: 6, expected: 7, rejected: 1 }
		]);
	});

	it.each([
		['not_started', 'neutral', 'The destination has not been promoted yet.'],
		['unchanged', 'warning', 'The existing destination index is unchanged.'],
		['promoted', 'success', 'The destination index was promoted.'],
		[
			'unknown',
			'danger',
			'Destination safety is unproven. Reconcile the destination before retrying into this target.'
		]
	] as const)('presents backend-authored %s publication disposition', (value, tone, message) => {
		expect(
			describeAlgoliaImportPublicationDisposition(
				publicJob({ publicationDisposition: value, error: null })
			)
		).toEqual({ tone, message });
	});

	it.each(ERROR_PRESENTATIONS)('maps backend error %s to stable copy', (code, expected) => {
		const producerMessage = `producer detail for ${code}`;

		expect(describeAlgoliaImportError({ code, message: producerMessage })).toBe(expected);
		expect(describeAlgoliaImportError({ code, message: null })).toBe(expected);
		expect(expected).not.toContain(producerMessage);
	});

	it('presents no failure copy when the backend reports no error', () => {
		expect(describeAlgoliaImportError(null)).toBeNull();
	});

	it('uses only closed DTO fields for disposition and action policy', () => {
		const failed = publicJob({
			status: 'failed',
			publicationDisposition: 'unknown',
			resumable: true
		});

		expect(describeAlgoliaImportPublicationDisposition(failed)).toEqual({
			tone: 'danger',
			message:
				'Destination safety is unproven. Reconcile the destination before retrying into this target.'
		});
		expect(describeAlgoliaImportJobActions(failed, { admitted: true })).toEqual({
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: 'Retry is blocked until destination reconciliation is complete.'
		});
	});

	it.each(['not_started', 'unchanged', 'promoted', 'unknown'] as const)(
		'describes replacement destination changes with %s disposition without implying erasure',
		(publicationDisposition) => {
			expect(
				describeAlgoliaImportPublicationDisposition(
					publicJob({
						mode: 'replace',
						destination: {
							kind: 'replace',
							target: 'existing_products',
							region: 'us-west-2'
						},
						status: 'failed',
						publicationDisposition,
						error: { code: 'destination_changed', message: null }
					})
				)
			).toEqual({
				tone: 'danger',
				message:
					'Replacement stopped because the destination changed. Legitimate destination document or configuration writes were preserved; retry only after both Algolia and fjcloud are quiet and with a new blank Algolia key.'
			});
		}
	);

	it('describes runtime admission backpressure with a typed reason and retry-after copy', () => {
		expect(
			describeAlgoliaImportAdmission({
				admitted: false,
				reason: 'runtime_backpressure',
				message: 'Import workers are saturated.',
				retryAfterSeconds: 90
			})
		).toEqual({
			title: 'Imports are temporarily busy',
			message: 'Import workers are saturated. Retry after 90 seconds.',
			disablesStarts: true
		});
	});

	it('keeps admission presentation reversible from ready to backpressure to ready', () => {
		expect(describeAlgoliaImportAdmission({ admitted: true })).toEqual({
			title: 'Imports available',
			message: '',
			disablesStarts: false
		});
		expect(
			describeAlgoliaImportAdmission({
				admitted: false,
				reason: 'repository_backpressure',
				message: 'Repository ACKs are delayed.',
				retryAfterSeconds: null
			})
		).toEqual({
			title: 'Imports are temporarily busy',
			message: 'Repository ACKs are delayed.',
			disablesStarts: true
		});
		expect(describeAlgoliaImportAdmission({ admitted: true })).toEqual({
			title: 'Imports available',
			message: '',
			disablesStarts: false
		});
	});

	it.each([
		['absent', undefined],
		['all false', NO_CAPABILITIES],
		['partial cancel omitted', { resume: true, replace: true } as AlgoliaMigrationCapabilities],
		[
			'malformed cancel by cast',
			{ cancel: 'true', resume: true, replace: true } as unknown as AlgoliaMigrationCapabilities
		]
	])('fails closed for %s cancel capability inputs', (_name, capabilities) => {
		expect(
			describeAlgoliaImportJobActions(
				publicJob({ status: 'copying_documents' }),
				undefined,
				capabilities
			)
		).toMatchObject({
			canCancel: false,
			canResume: false
		});
	});

	it.each([
		['absent', undefined],
		['all false', NO_CAPABILITIES],
		['partial resume omitted', { cancel: true, replace: true } as AlgoliaMigrationCapabilities],
		[
			'malformed resume by cast',
			{ cancel: true, resume: 'true', replace: true } as unknown as AlgoliaMigrationCapabilities
		]
	])('fails closed for %s resume capability inputs', (_name, capabilities) => {
		expect(
			describeAlgoliaImportJobActions(
				publicJob({ status: 'failed', resumable: true, publicationDisposition: 'unchanged' }),
				undefined,
				capabilities
			)
		).toMatchObject({
			canCancel: false,
			canResume: false
		});
	});

	it('gates cancel and resume independently without using availability as an action gate', () => {
		const running = publicJob({ status: 'copying_documents' });
		const resumableFailure = publicJob({
			status: 'failed',
			resumable: true,
			publicationDisposition: 'unchanged'
		});

		expect(
			describeAlgoliaImportJobActions(running, undefined, {
				cancel: true,
				resume: false,
				replace: false
			})
		).toMatchObject({
			canCancel: true,
			canResume: false
		});
		expect(
			describeAlgoliaImportJobActions(resumableFailure, undefined, {
				cancel: false,
				resume: true,
				replace: false
			})
		).toMatchObject({
			canCancel: false,
			canResume: true
		});
		expect(
			describeAlgoliaImportJobActions(running, undefined, {
				cancel: false,
				resume: false,
				replace: true
			})
		).toMatchObject({
			canCancel: false,
			canResume: false
		});
	});

	it.each([
		['invalid credentials', 'failed', 'invalid_credentials'],
		['missing source permission', 'failed', 'missing_source_permission'],
		['engine-marked interruption', 'interrupted', 'interrupted']
	] as const)(
		'enables resume for a resumable %s fixture when the capability is true',
		(_name, status, code) => {
			expect(
				describeAlgoliaImportJobActions(
					publicJob({
						status,
						resumable: true,
						publicationDisposition: 'unchanged',
						error: { code, message: null }
					}),
					undefined,
					{ cancel: false, resume: true, replace: false }
				)
			).toMatchObject({
				canResume: true,
				canStartNewImport: false,
				retryCopy:
					'Reconnect to Algolia with a fresh key. Already-imported records are skipped when the import resumes.'
			});
		}
	);

	it('offers only a start-over path for non-resumable terminal failures', () => {
		expect(
			describeAlgoliaImportJobActions(
				publicJob({
					status: 'failed',
					resumable: false,
					publicationDisposition: 'unchanged',
					error: { code: 'not_resumable', message: null }
				}),
				undefined,
				{ cancel: false, resume: true, replace: false }
			)
		).toMatchObject({
			canResume: false,
			canStartNewImport: true,
			canEnterRetryKey: false,
			retryCopy: null
		});
	});

	it.each(['runtime_backpressure', 'operational_pause'] as const)(
		'disables resume during %s while keeping a retry policy',
		(reason) => {
			expect(
				describeAlgoliaImportJobActions(
					publicJob({
						status: 'interrupted',
						resumable: true,
						publicationDisposition: 'unchanged',
						error: { code: 'interrupted', message: null }
					}),
					{
						admitted: false,
						reason,
						message: 'Migration starts are paused.',
						retryAfterSeconds: null
					},
					{ cancel: true, resume: true, replace: false }
				)
			).toMatchObject({
				canCancel: false,
				canResume: false,
				canStartNewImport: false,
				canEnterRetryKey: false,
				retryCopy: 'Migration starts are paused.'
			});
		}
	);
});
