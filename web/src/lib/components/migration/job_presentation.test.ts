import { describe, expect, it } from 'vitest';

import type {
	AlgoliaImportWarning,
	AlgoliaMigrationCapabilities,
	PublicAlgoliaImportError
} from '$lib/api/types';
import {
	algoliaImportCompatibilityWarningPresentation,
	algoliaImportSummaryRows,
	describeAlgoliaImportAdmission,
	describeAlgoliaImportError,
	describeAlgoliaImportJobActions,
	describeAlgoliaImportPublicationDisposition,
	describeAlgoliaImportStatus
} from './job_presentation';
import { NO_MIGRATION_CAPABILITIES, publicImportJob } from './migration_test_fixtures';

const ALL_STATUSES: Array<ReturnType<typeof describeAlgoliaImportStatus>> = [
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
	[
		'migration_provider_unsupported',
		'This destination provider does not support migration imports.'
	],
	['source_provider_unsupported', 'This source provider is not supported for search imports yet.'],
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

	it.each(['copying_documents', 'failed', 'cancelled', 'completed'] as const)(
		'renders documents only for %s jobs without an observed terminal outcome',
		(status) => {
			const rows = algoliaImportSummaryRows(
				publicImportJob({ status, terminalOutcomeObserved: false })
			);

			expect(rows).toEqual([
				{ kind: 'documents', label: 'Documents', imported: 13, expected: 17, rejected: 4 }
			]);
			expect(JSON.stringify(rows)).not.toMatch(/Settings|Synonyms|Rules/);
		}
	);

	it('preserves an observed all-zero terminal outcome without fabricating denominators', () => {
		expect(
			algoliaImportSummaryRows(
				publicImportJob({
					summary: {
						...publicImportJob().summary,
						settingsApplied: 0,
						synonymsImported: 0,
						rulesImported: 0
					}
				})
			)
		).toEqual([
			{ kind: 'documents', label: 'Documents', imported: 13, expected: 17, rejected: 4 },
			{ kind: 'settings', label: 'Settings', applied: false },
			{ kind: 'imported', label: 'Synonyms', imported: 0 },
			{ kind: 'imported', label: 'Rules', imported: 0 }
		]);
	});

	it('presents only observed terminal facts for a nonzero outcome', () => {
		expect(algoliaImportSummaryRows(publicImportJob())).toEqual([
			{ kind: 'documents', label: 'Documents', imported: 13, expected: 17, rejected: 4 },
			{ kind: 'settings', label: 'Settings', applied: true },
			{ kind: 'imported', label: 'Synonyms', imported: 3 },
			{ kind: 'imported', label: 'Rules', imported: 6 }
		]);
	});

	it('presents every warning in raw-resource groups without losing producer detail', () => {
		const warnings: AlgoliaImportWarning[] = [
			{
				code: 'unsupported_setting_0',
				message: 'Settings warning zero.',
				resource: 'settings',
				pageIndex: 1,
				itemIndex: 0,
				jsonPath: '$.settings[0]'
			},
			{
				code: 'unsupported_setting_1',
				message: 'Settings warning one.',
				resource: 'settings',
				pageIndex: null,
				itemIndex: 1,
				jsonPath: '$.settings[1]'
			},
			{
				code: 'unsupported_setting_2',
				message: 'Settings warning two.',
				resource: 'settings',
				pageIndex: 2,
				itemIndex: null,
				jsonPath: ''
			},
			{
				code: 'unsupported_index_option_0',
				message: 'Hyphenated resource zero.',
				resource: 'index-settings',
				pageIndex: 3,
				itemIndex: 0,
				jsonPath: '$.indexSettings[0]'
			},
			{
				code: 'unsupported_index_option_1',
				message: 'Hyphenated resource one.',
				resource: 'index-settings',
				pageIndex: null,
				itemIndex: null,
				jsonPath: ''
			},
			{
				code: 'unsupported_index_option_2',
				message: 'Underscored resource zero.',
				resource: 'index_settings',
				pageIndex: 4,
				itemIndex: 2,
				jsonPath: '$.indexSettings[2]'
			},
			{
				code: 'unsupported_index_option_3',
				message: 'Underscored resource one.',
				resource: 'index_settings',
				pageIndex: null,
				itemIndex: 3,
				jsonPath: '$.indexSettings[3]'
			},
			{
				code: 'unsupported_synonym_type_0',
				message: 'Synonym warning zero.',
				resource: 'synonyms',
				pageIndex: 2,
				itemIndex: 5,
				jsonPath: '$.synonyms[5]'
			},
			{
				code: 'unsupported_synonym_type_1',
				message: 'Synonym warning one.',
				resource: 'synonyms',
				pageIndex: 5,
				itemIndex: 6,
				jsonPath: '$.synonyms[6]'
			},
			{
				code: 'unsupported_synonym_type_2',
				message: 'Synonym warning two.',
				resource: 'synonyms',
				pageIndex: null,
				itemIndex: null,
				jsonPath: '$.synonyms[7]'
			}
		];

		const presentation = algoliaImportCompatibilityWarningPresentation(
			publicImportJob({ status: 'completed_with_warnings', warnings })
		);

		expect(presentation).toEqual({
			summary: 'Import completed with 10 compatibility warnings.',
			groups: [
				{
					resource: 'settings',
					resourceLabel: 'settings',
					warnings: [
						{
							code: 'unsupported_setting_0',
							message: 'Settings warning zero.',
							locator: 'page 1, item 0, path $.settings[0]'
						},
						{
							code: 'unsupported_setting_1',
							message: 'Settings warning one.',
							locator: 'item 1, path $.settings[1]'
						},
						{ code: 'unsupported_setting_2', message: 'Settings warning two.', locator: 'page 2' }
					]
				},
				{
					resource: 'index-settings',
					resourceLabel: 'index settings',
					warnings: [
						{
							code: 'unsupported_index_option_0',
							message: 'Hyphenated resource zero.',
							locator: 'page 3, item 0, path $.indexSettings[0]'
						},
						{
							code: 'unsupported_index_option_1',
							message: 'Hyphenated resource one.',
							locator: null
						}
					]
				},
				{
					resource: 'index_settings',
					resourceLabel: 'index settings',
					warnings: [
						{
							code: 'unsupported_index_option_2',
							message: 'Underscored resource zero.',
							locator: 'page 4, item 2, path $.indexSettings[2]'
						},
						{
							code: 'unsupported_index_option_3',
							message: 'Underscored resource one.',
							locator: 'item 3, path $.indexSettings[3]'
						}
					]
				},
				{
					resource: 'synonyms',
					resourceLabel: 'synonyms',
					warnings: [
						{
							code: 'unsupported_synonym_type_0',
							message: 'Synonym warning zero.',
							locator: 'page 2, item 5, path $.synonyms[5]'
						},
						{
							code: 'unsupported_synonym_type_1',
							message: 'Synonym warning one.',
							locator: 'page 5, item 6, path $.synonyms[6]'
						},
						{
							code: 'unsupported_synonym_type_2',
							message: 'Synonym warning two.',
							locator: 'path $.synonyms[7]'
						}
					]
				}
			]
		});
		expect(presentation?.groups.flatMap((group) => group.warnings)).toHaveLength(warnings.length);
		expect(presentation?.summary).not.toMatch(/\band \d+ more warnings?\b/);
	});

	it('bounds every displayed warning field without dropping grouped warnings', () => {
		const hiddenResourceTail = 'RESOURCE_HIDDEN_TAIL';
		const hiddenCodeTail = 'CODE_HIDDEN_TAIL';
		const hiddenMessageTail = 'MESSAGE_HIDDEN_TAIL';
		const hiddenPathTail = 'PATH_HIDDEN_TAIL';
		const warning = {
			code: `${'c'.repeat(79)}${hiddenCodeTail}`,
			message: `${'m'.repeat(78)}🙂${hiddenMessageTail}`,
			resource: `${'r'.repeat(79)}${hiddenResourceTail}`,
			pageIndex: 8,
			itemIndex: 13,
			jsonPath: `${'$'.repeat(79)}${hiddenPathTail}`
		};

		const presentation = algoliaImportCompatibilityWarningPresentation(
			publicImportJob({
				status: 'completed_with_warnings',
				warnings: [
					warning,
					{
						code: 'short_warning',
						message: 'Short warning.',
						resource: warning.resource,
						pageIndex: null,
						itemIndex: null,
						jsonPath: ''
					}
				]
			})
		);

		expect(presentation).toEqual({
			summary: 'Import completed with 2 compatibility warnings.',
			groups: [
				{
					resource: warning.resource,
					resourceLabel: `${'r'.repeat(79)}…`,
					warnings: [
						{
							code: `${'c'.repeat(79)}…`,
							message: `${'m'.repeat(78)}🙂…`,
							locator: `page 8, item 13, path ${'$'.repeat(79)}…`
						},
						{
							code: 'short_warning',
							message: 'Short warning.',
							locator: null
						}
					]
				}
			]
		});
		expect(presentation?.groups.flatMap((group) => group.warnings)).toHaveLength(2);
		const customerVisiblePresentation = JSON.stringify({
			summary: presentation?.summary,
			groups: presentation?.groups.map(({ resourceLabel, warnings }) => ({
				resourceLabel,
				warnings
			}))
		});
		expect(customerVisiblePresentation).not.toContain(hiddenResourceTail);
		expect(customerVisiblePresentation).not.toContain(hiddenCodeTail);
		expect(customerVisiblePresentation).not.toContain(hiddenMessageTail);
		expect(customerVisiblePresentation).not.toContain(hiddenPathTail);
	});

	it('uses warning payload presence rather than lifecycle inference for visibility', () => {
		const presentation = algoliaImportCompatibilityWarningPresentation(
			publicImportJob({
				status: 'copying_documents',
				terminalOutcomeObserved: false,
				warnings: [
					{
						code: 'unsupported_synonym_type',
						message: 'The synonym type must be changed before retrying.',
						resource: 'synonyms',
						pageIndex: 2,
						itemIndex: 5,
						jsonPath: '$.synonyms[5]'
					}
				]
			})
		);

		expect(presentation).toEqual({
			summary: 'This import has 1 compatibility warning.',
			groups: [
				{
					resource: 'synonyms',
					resourceLabel: 'synonyms',
					warnings: [
						{
							code: 'unsupported_synonym_type',
							message: 'The synonym type must be changed before retrying.',
							locator: 'page 2, item 5, path $.synonyms[5]'
						}
					]
				}
			]
		});
	});

	it('returns no warning presentation for an empty warning payload', () => {
		expect(
			algoliaImportCompatibilityWarningPresentation(publicImportJob({ warnings: [] }))
		).toBeNull();
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
				publicImportJob({ publicationDisposition: value, error: null })
			)
		).toEqual({ tone, message });
	});

	it.each(ERROR_PRESENTATIONS)('maps backend error %s to stable copy', (code, expected) => {
		expect(describeAlgoliaImportError(publicImportJob({ error: { code } }))).toBe(expected);
	});

	it('presents no failure copy when the backend reports no error', () => {
		expect(describeAlgoliaImportError(publicImportJob({ error: null }))).toBeNull();
	});

	it('renders provider-specific source-credential copy for non-Algolia jobs', () => {
		expect(
			describeAlgoliaImportError(
				publicImportJob({
					sourceProvider: 'meilisearch',
					error: { code: 'invalid_credentials' }
				})
			)
		).toBe('Meilisearch credentials were rejected. Reconnect with a valid key.');
		expect(
			describeAlgoliaImportError(
				publicImportJob({
					sourceProvider: 'typesense',
					error: { code: 'missing_source_permission' }
				})
			)
		).toBe('The Typesense key does not have permission to read the source index.');
	});

	it('uses only closed DTO fields for disposition and action policy', () => {
		const failed = publicImportJob({
			status: 'failed',
			publicationDisposition: 'unknown',
			resumable: true
		});

		expect(describeAlgoliaImportPublicationDisposition(failed)).toEqual({
			tone: 'danger',
			message:
				'Destination safety is unproven. Reconcile the destination before retrying into this target.'
		});
		expect(
			describeAlgoliaImportJobActions(failed, { admitted: true }, NO_MIGRATION_CAPABILITIES)
		).toEqual({
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: null
		});
	});

	it.each(['not_started', 'unchanged', 'promoted', 'unknown'] as const)(
		'describes replacement destination changes with %s disposition without implying erasure',
		(publicationDisposition) => {
			expect(
				describeAlgoliaImportPublicationDisposition(
					publicImportJob({
						mode: 'replace',
						destination: {
							kind: 'replace',
							target: 'existing_products',
							region: 'us-west-2'
						},
						status: 'failed',
						publicationDisposition,
						error: { code: 'destination_changed' }
					})
				)
			).toEqual({
				tone: 'danger',
				message:
					'Replacement stopped because the destination changed. Legitimate destination document or configuration writes were preserved; retry only after both Algolia and fjcloud are quiet and with a new blank Algolia key.'
			});
		}
	);

	it('uses the job source provider in replacement retry guidance', () => {
		expect(
			describeAlgoliaImportPublicationDisposition(
				publicImportJob({
					sourceProvider: 'meilisearch',
					mode: 'replace',
					destination: {
						kind: 'replace',
						target: 'existing_products',
						region: 'us-west-2'
					},
					status: 'failed',
					publicationDisposition: 'unchanged',
					error: { code: 'destination_changed' }
				})
			)
		).toEqual({
			tone: 'danger',
			message:
				'Replacement stopped because the destination changed. Legitimate destination document or configuration writes were preserved; retry only after both Meilisearch and fjcloud are quiet and with a new blank Meilisearch key.'
		});
	});

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
		['all false', NO_MIGRATION_CAPABILITIES],
		['partial cancel omitted', { resume: true, replace: true } as AlgoliaMigrationCapabilities],
		[
			'malformed cancel by cast',
			{ cancel: 'true', resume: true, replace: true } as unknown as AlgoliaMigrationCapabilities
		]
	])('fails closed for %s cancel capability inputs', (_name, capabilities) => {
		expect(
			describeAlgoliaImportJobActions(
				publicImportJob({ status: 'copying_documents' }),
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
		['all false', NO_MIGRATION_CAPABILITIES],
		['partial resume omitted', { cancel: true, replace: true } as AlgoliaMigrationCapabilities],
		[
			'malformed resume by cast',
			{ cancel: true, resume: 'true', replace: true } as unknown as AlgoliaMigrationCapabilities
		]
	])('fails closed for %s resume capability inputs', (_name, capabilities) => {
		expect(
			describeAlgoliaImportJobActions(
				publicImportJob({ status: 'failed', resumable: true, publicationDisposition: 'unchanged' }),
				undefined,
				capabilities
			)
		).toEqual({
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: null
		});
	});

	it('gates cancel and resume independently without using availability as an action gate', () => {
		const running = publicImportJob({ status: 'copying_documents' });
		const resumableFailure = publicImportJob({
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
					publicImportJob({
						status,
						resumable: true,
						publicationDisposition: 'unchanged',
						error: { code }
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

	it('uses the job source provider in resumable retry guidance', () => {
		expect(
			describeAlgoliaImportJobActions(
				publicImportJob({
					sourceProvider: 'typesense',
					status: 'failed',
					resumable: true,
					publicationDisposition: 'unchanged',
					error: { code: 'invalid_credentials' }
				}),
				undefined,
				{ cancel: false, resume: true, replace: false }
			)
		).toMatchObject({
			canResume: true,
			retryCopy:
				'Reconnect to Typesense with a fresh key. Already-imported records are skipped when the import resumes.'
		});
	});

	it('offers only a start-over path for non-resumable terminal failures', () => {
		expect(
			describeAlgoliaImportJobActions(
				publicImportJob({
					status: 'failed',
					resumable: false,
					publicationDisposition: 'unchanged',
					error: { code: 'not_resumable' }
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
					publicImportJob({
						status: 'interrupted',
						resumable: true,
						publicationDisposition: 'unchanged',
						error: { code: 'interrupted' }
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
