import { describe, expect, it } from 'vitest';

import type { MigrationPreviewResponse } from '$lib/api/types';
import {
	describeMigrationPreviewFailure,
	MIGRATION_PREVIEW_NO_JOB_STATEMENT,
	migrationPreviewCompatibilityWarningPresentation
} from './job_presentation';

describe('migration preview warning presentation', () => {
	it('presents report entries through the shared compatibility warning shape', () => {
		const preview: MigrationPreviewResponse = {
			sourceCounts: { indexes: 3, records: 42 },
			report: {
				summary: { totalEntries: 3, hardRejections: 1, warnings: 1, scopeGaps: 1 },
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
					},
					{
						severity: 'ScopeGap',
						code: 'ProductNotMigrated',
						resource: 'Analytics',
						pageIndex: null,
						itemIndex: null,
						jsonPath: ''
					}
				],
				reportDigest: 'sha256:test-preview-report'
			}
		};

		expect(migrationPreviewCompatibilityWarningPresentation(preview)).toEqual({
			summary:
				'Preview found 3 compatibility findings: 1 hard rejection, 1 warning, and 1 scope gap.',
			groups: [
				{
					resource: 'Settings',
					resourceLabel: 'Settings',
					warnings: [
						{
							code: 'UnsupportedSourceField',
							message: 'Compatibility warning',
							severity: 'Warning',
							locator: 'item 0, path $.settings.attributesForFaceting[0]'
						}
					]
				},
				{
					resource: 'Document',
					resourceLabel: 'Document',
					warnings: [
						{
							code: 'MalformedDocumentPayload',
							message: 'Compatibility warning',
							severity: 'Hard rejection',
							locator: 'page 1, item 7, path $.hits[7]'
						}
					]
				},
				{
					resource: 'Analytics',
					resourceLabel: 'Analytics',
					warnings: [
						{
							code: 'ProductNotMigrated',
							message: 'Compatibility warning',
							severity: 'Scope gap',
							locator: null
						}
					]
				}
			]
		});
	});

	it('treats omitted preview entry indexes as absent locator parts', () => {
		const preview: MigrationPreviewResponse = {
			sourceCounts: { indexes: 1, records: 1 },
			report: {
				summary: { totalEntries: 1, hardRejections: 0, warnings: 1, scopeGaps: 0 },
				entries: [
					{
						severity: 'Warning',
						code: 'UnsupportedSourceField',
						resource: 'Settings',
						jsonPath: '$.settings.searchableAttributes[0]'
					}
				],
				reportDigest: 'sha256:omitted-index-preview-report'
			}
		};

		expect(
			migrationPreviewCompatibilityWarningPresentation(preview)?.groups[0]?.warnings[0]
		).toEqual({
			code: 'UnsupportedSourceField',
			message: 'Compatibility warning',
			severity: 'Warning',
			locator: 'path $.settings.searchableAttributes[0]'
		});
	});

	it('returns no warning presentation when the report has no entries', () => {
		const preview: MigrationPreviewResponse = {
			sourceCounts: { indexes: 1, records: 3 },
			report: {
				summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
				entries: [],
				reportDigest: 'sha256:clean-preview-report'
			}
		};

		expect(migrationPreviewCompatibilityWarningPresentation(preview)).toBeNull();
	});
});

describe('migration preview failure presentation', () => {
	it('states that no preview completed and no job was created', () => {
		expect(MIGRATION_PREVIEW_NO_JOB_STATEMENT).toBe(
			'No preview was completed and no import job was created.'
		);
	});

	it('resolves source_provider_unsupported through the shared migration error copy', () => {
		expect(describeMigrationPreviewFailure('typesense', 'source_provider_unsupported')).toEqual({
			detail: 'This source provider is not supported for search imports yet.',
			statement: 'No preview was completed and no import job was created.'
		});
	});

	it('labels rejected credentials with the selected source provider', () => {
		expect(describeMigrationPreviewFailure('meilisearch', 'invalid_credentials')).toEqual({
			detail: 'Meilisearch credentials were rejected. Reconnect with a valid key.',
			statement: 'No preview was completed and no import job was created.'
		});
	});

	it('keeps an unrecognized sanitized message as the detail line verbatim', () => {
		expect(
			describeMigrationPreviewFailure('algolia', '  fetch failed: [redacted] retryable  ')
		).toEqual({
			detail: 'fetch failed: [redacted] retryable',
			statement: 'No preview was completed and no import job was created.'
		});
	});

	it('keeps Object prototype property names as unrecognized sanitized messages', () => {
		expect(describeMigrationPreviewFailure('algolia', 'toString')).toEqual({
			detail: 'toString',
			statement: 'No preview was completed and no import job was created.'
		});
	});

	it('falls back to the statement alone when the sanitized message is empty', () => {
		expect(describeMigrationPreviewFailure('algolia', '   ')).toEqual({
			detail: null,
			statement: 'No preview was completed and no import job was created.'
		});
	});
});
