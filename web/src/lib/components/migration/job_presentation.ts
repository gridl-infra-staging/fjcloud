import type {
	AlgoliaImportWarning,
	AlgoliaImportJobStatus,
	AlgoliaMigrationCapabilities,
	MigrationPreviewResponse,
	PublicAlgoliaImportError,
	PublicAlgoliaImportJob,
	SourceProvider
} from '$lib/api/types';
import { migrationSourceProviderLabel } from './create_success_intent';

export type AlgoliaImportStatusPresentation = {
	status: AlgoliaImportJobStatus;
	label: string;
	phase: string;
	running: boolean;
	terminal: boolean;
};

export type AlgoliaImportSummaryRow =
	| {
			kind: 'documents';
			label: 'Documents';
			imported: number;
			expected: number;
			rejected: number;
	  }
	| {
			kind: 'settings';
			label: 'Settings';
			applied: boolean;
	  }
	| {
			kind: 'imported';
			label: 'Synonyms' | 'Rules';
			imported: number;
	  };

export type AlgoliaImportAdmission =
	| { admitted: true }
	| {
			admitted: false;
			reason: 'runtime_backpressure' | 'repository_backpressure' | 'operational_pause';
			message: string;
			retryAfterSeconds: number | null;
	  };

export type AlgoliaImportAdmissionPresentation = {
	title: string;
	message: string;
	disablesStarts: boolean;
};

export type AlgoliaImportDispositionPresentation = {
	tone: 'neutral' | 'success' | 'warning' | 'danger';
	message: string;
};

export type AlgoliaImportActionPresentation = {
	canViewIndex: boolean;
	canTestSearch: boolean;
	canCancel: boolean;
	canResume: boolean;
	canStartNewImport: boolean;
	canEnterRetryKey: boolean;
	retryCopy: string | null;
};

export type AlgoliaImportCompatibilityWarningEntry = {
	code: string;
	message: string;
	severity?: string;
	locator: string | null;
};

export type AlgoliaImportCompatibilityWarningGroup = {
	resource: string;
	resourceLabel: string;
	warnings: AlgoliaImportCompatibilityWarningEntry[];
};

export type AlgoliaImportCompatibilityWarningPresentation = {
	summary: string;
	groups: AlgoliaImportCompatibilityWarningGroup[];
};

const STATUS_PRESENTATION: Record<AlgoliaImportJobStatus, AlgoliaImportStatusPresentation> = {
	queued: {
		status: 'queued',
		label: 'Queued',
		phase: 'Waiting to start',
		running: true,
		terminal: false
	},
	validating_source: {
		status: 'validating_source',
		label: 'Validating source',
		phase: 'Checking source access',
		running: true,
		terminal: false
	},
	copying_configuration: {
		status: 'copying_configuration',
		label: 'Copying configuration',
		phase: 'Copying settings, synonyms, and rules',
		running: true,
		terminal: false
	},
	copying_documents: {
		status: 'copying_documents',
		label: 'Copying documents',
		phase: 'Copying records',
		running: true,
		terminal: false
	},
	verifying: {
		status: 'verifying',
		label: 'Verifying',
		phase: 'Verifying imported data',
		running: true,
		terminal: false
	},
	promoting: {
		status: 'promoting',
		label: 'Promoting',
		phase: 'Promoting destination',
		running: true,
		terminal: false
	},
	cancelling: {
		status: 'cancelling',
		label: 'Cancelling',
		phase: 'Stopping import',
		running: true,
		terminal: false
	},
	cancelled: {
		status: 'cancelled',
		label: 'Cancelled',
		phase: 'Stopped before completion',
		running: false,
		terminal: true
	},
	resuming: {
		status: 'resuming',
		label: 'Resuming',
		phase: 'Preparing resume',
		running: true,
		terminal: false
	},
	completed: {
		status: 'completed',
		label: 'Completed',
		phase: 'Import complete',
		running: false,
		terminal: true
	},
	completed_with_warnings: {
		status: 'completed_with_warnings',
		label: 'Completed with warnings',
		phase: 'Import complete with warnings',
		running: false,
		terminal: true
	},
	failed: {
		status: 'failed',
		label: 'Failed',
		phase: 'Import failed',
		running: false,
		terminal: true
	},
	interrupted: {
		status: 'interrupted',
		label: 'Interrupted',
		phase: 'Import interrupted',
		running: false,
		terminal: true
	}
};

const ADMITTED: AlgoliaImportAdmission = { admitted: true };
const NO_JOB_ACTIONS: AlgoliaImportActionPresentation = {
	canViewIndex: false,
	canTestSearch: false,
	canCancel: false,
	canResume: false,
	canStartNewImport: false,
	canEnterRetryKey: false,
	retryCopy: null
};

const STATIC_ERROR_COPY: Record<
	Exclude<
		PublicAlgoliaImportError['code'],
		'invalid_credentials' | 'missing_source_permission' | 'source_catalog_too_large'
	>,
	string
> = {
	source_not_found: 'The source index could not be found.',
	destination_conflict: 'The destination index conflicts with another import.',
	quota_exceeded: 'The import exceeds the destination quota.',
	source_too_large: 'The source index is too large to import.',
	insufficient_engine_storage: 'The destination does not have enough storage for this import.',
	destination_changed: 'The destination changed while the import was running.',
	source_changed: 'The source changed while the import was running.',
	incompatible_data: 'Some source data is not compatible with the destination.',
	engine_upgrade_required: 'The destination must be upgraded before this import can continue.',
	migration_ha_not_supported: 'This import is not supported for high-availability destinations.',
	migration_provider_unsupported: 'This destination provider does not support migration imports.',
	source_provider_unsupported: 'This source provider is not supported for search imports yet.',
	backend_unavailable: 'The migration service is temporarily unavailable.',
	interrupted: 'The import was interrupted before it completed.',
	cancel_not_permitted: 'This import can no longer be cancelled.',
	not_resumable: 'This import cannot be resumed. Start a new import instead.',
	internal: 'The import stopped because of an internal error.'
};

export function defaultAlgoliaImportAdmission(): AlgoliaImportAdmission {
	return ADMITTED;
}

export function describeAlgoliaImportStatus(
	status: AlgoliaImportJobStatus
): AlgoliaImportStatusPresentation {
	return STATUS_PRESENTATION[status];
}

const PROVIDER_LABELLED_ERROR_COPY: Record<
	'invalid_credentials' | 'missing_source_permission' | 'source_catalog_too_large',
	(sourceProviderLabel: string) => string
> = {
	invalid_credentials: (label) => `${label} credentials were rejected. Reconnect with a valid key.`,
	missing_source_permission: (label) =>
		`The ${label} key does not have permission to read the source index.`,
	source_catalog_too_large: (label) => `The ${label} source catalog is too large to import.`
};

function describeMigrationErrorCode(
	code: PublicAlgoliaImportError['code'],
	sourceProvider: SourceProvider
): string {
	const providerLabelled = PROVIDER_LABELLED_ERROR_COPY[
		code as keyof typeof PROVIDER_LABELLED_ERROR_COPY
	] as ((sourceProviderLabel: string) => string) | undefined;
	return providerLabelled === undefined
		? STATIC_ERROR_COPY[code as keyof typeof STATIC_ERROR_COPY]
		: providerLabelled(migrationSourceProviderLabel(sourceProvider));
}

function isMigrationErrorCode(value: string): value is PublicAlgoliaImportError['code'] {
	return (
		Object.hasOwn(STATIC_ERROR_COPY, value) || Object.hasOwn(PROVIDER_LABELLED_ERROR_COPY, value)
	);
}

export function describeAlgoliaImportError(job: PublicAlgoliaImportJob): string | null {
	return job.error === null ? null : describeMigrationErrorCode(job.error.code, job.sourceProvider);
}

// Preview is report-only, so its failures must always say so: the customer needs
// to know the flow did not silently create an import. Detail resolves through the
// same code copy the retained job detail renders, so pre- and post-import failures
// for one code never diverge.
export const MIGRATION_PREVIEW_NO_JOB_STATEMENT =
	'No preview was completed and no import job was created.';

export interface MigrationPreviewFailurePresentation {
	detail: string | null;
	statement: string;
}

export interface MigrationVerificationFailurePresentation {
	message: string;
	code: string | null;
}

export function describeMigrationPreviewFailure(
	sourceProvider: SourceProvider,
	sanitizedError: string
): MigrationPreviewFailurePresentation {
	const sanitized = sanitizedError.trim();
	const detail = isMigrationErrorCode(sanitized)
		? describeMigrationErrorCode(sanitized, sourceProvider)
		: sanitized;
	return { detail: detail === '' ? null : detail, statement: MIGRATION_PREVIEW_NO_JOB_STATEMENT };
}

export function describeMigrationSubmitFailure(
	sourceProvider: SourceProvider,
	sanitizedError: string
): string {
	const sanitized = sanitizedError.trim();
	return isMigrationErrorCode(sanitized)
		? describeMigrationErrorCode(sanitized, sourceProvider)
		: sanitizedError;
}

const VERIFICATION_ERROR_COPY: Partial<
	Record<PublicAlgoliaImportError['code'] | 'verification_not_available', string>
> = {
	invalid_credentials:
		'Algolia credentials were rejected. Enter a valid key and run verification again.',
	missing_source_permission: 'The Algolia key does not have permission to search the source index.',
	source_not_found: STATIC_ERROR_COPY.source_not_found,
	backend_unavailable: 'The comparison service is temporarily unavailable.',
	incompatible_data: 'The verification request or destination response could not be compared.',
	source_provider_unsupported: STATIC_ERROR_COPY.source_provider_unsupported,
	migration_provider_unsupported: STATIC_ERROR_COPY.migration_provider_unsupported,
	destination_conflict: STATIC_ERROR_COPY.destination_conflict,
	quota_exceeded: STATIC_ERROR_COPY.quota_exceeded,
	engine_upgrade_required: STATIC_ERROR_COPY.engine_upgrade_required,
	internal: STATIC_ERROR_COPY.internal,
	verification_not_available: 'Cutover verification is available only after the import completes.'
};

export function describeMigrationVerificationFailure(
	sourceProvider: SourceProvider,
	error: { code?: string | null; message?: string | null } | null
): MigrationVerificationFailurePresentation | null {
	if (error === null) return null;
	const code =
		typeof error.code === 'string' && error.code.trim() !== '' ? error.code.trim() : null;
	if (code !== null && Object.hasOwn(VERIFICATION_ERROR_COPY, code)) {
		return {
			code,
			message: VERIFICATION_ERROR_COPY[code as keyof typeof VERIFICATION_ERROR_COPY] as string
		};
	}
	const message = typeof error.message === 'string' ? error.message.trim() : '';
	if (message !== '') return { code, message };
	if (code !== null && isMigrationErrorCode(code)) {
		return { code, message: describeMigrationErrorCode(code, sourceProvider) };
	}
	return { code, message: 'Cutover verification could not be completed.' };
}

/**
 * Customer-visible copy for a retained job whose source provider has no
 * server-published `capabilities.verify`.
 *
 * The wording deliberately states only what this panel cannot do. It must stay
 * true when verification is withheld for a reason other than provider support
 * (an operator-disabled platform withholds it for Algolia too), so it never
 * names Algolia as the supported source or promises a future release.
 *
 * The single owner of this sentence. `MigrationCutoverVerification.test.ts`
 * pins the literal wording; every other consumer asserts through this builder.
 */
export function describeUnsupportedCutoverVerification(sourceProvider: SourceProvider): string {
	const providerLabel = migrationSourceProviderLabel(sourceProvider);
	return (
		`Cutover verification is not available for this ${providerLabel} migration, ` +
		'so you cannot compare source and fjcloud search results here. The completed ' +
		'migration and any preview support published for it are unaffected.'
	);
}

export function algoliaImportSummaryRows(job: PublicAlgoliaImportJob): AlgoliaImportSummaryRow[] {
	const { summary } = job;
	const rows: AlgoliaImportSummaryRow[] = [
		{
			kind: 'documents',
			label: 'Documents',
			imported: summary.documentsImported,
			expected: summary.documentsExpected,
			rejected: summary.documentsRejected
		}
	];
	const hasObservedTerminalOutcome =
		job.terminalOutcomeObserved &&
		(job.status === 'completed' || job.status === 'completed_with_warnings');
	if (!hasObservedTerminalOutcome) {
		return rows;
	}
	rows.push(
		{
			kind: 'settings',
			label: 'Settings',
			applied: summary.settingsApplied > 0
		},
		{
			kind: 'imported',
			label: 'Synonyms',
			imported: summary.synonymsImported
		},
		{
			kind: 'imported',
			label: 'Rules',
			imported: summary.rulesImported
		}
	);
	return rows;
}

export function describeAlgoliaImportPublicationDisposition(
	job: PublicAlgoliaImportJob
): AlgoliaImportDispositionPresentation {
	if (job.mode === 'replace' && job.error?.code === 'destination_changed') {
		const sourceProviderLabel = migrationSourceProviderLabel(job.sourceProvider);
		return {
			tone: 'danger',
			message: `Replacement stopped because the destination changed. Legitimate destination document or configuration writes were preserved; retry only after both ${sourceProviderLabel} and fjcloud are quiet and with a new blank ${sourceProviderLabel} key.`
		};
	}
	switch (job.publicationDisposition) {
		case 'not_started':
			return { tone: 'neutral', message: 'The destination has not been promoted yet.' };
		case 'unchanged':
			return { tone: 'warning', message: 'The existing destination index is unchanged.' };
		case 'promoted':
			return { tone: 'success', message: 'The destination index was promoted.' };
		case 'unknown':
			return {
				tone: 'danger',
				message:
					'Destination safety is unproven. Reconcile the destination before retrying into this target.'
			};
	}
}

export function describeAlgoliaImportAdmission(
	admission: AlgoliaImportAdmission = ADMITTED
): AlgoliaImportAdmissionPresentation {
	if (admission.admitted) {
		return { title: 'Imports available', message: '', disablesStarts: false };
	}
	const retryCopy =
		admission.retryAfterSeconds === null
			? ''
			: ` Retry after ${admission.retryAfterSeconds} seconds.`;
	if (admission.reason === 'operational_pause') {
		return {
			title: 'New imports paused',
			message: `${admission.message}${retryCopy}`,
			disablesStarts: true
		};
	}
	return {
		title: 'Imports are temporarily busy',
		message: `${admission.message}${retryCopy}`,
		disablesStarts: true
	};
}

export function describeAlgoliaImportJobActions(
	job: PublicAlgoliaImportJob,
	admission: AlgoliaImportAdmission = ADMITTED,
	capabilities?: AlgoliaMigrationCapabilities
): AlgoliaImportActionPresentation {
	const status = describeAlgoliaImportStatus(job.status);
	const canCancel = capabilities?.cancel === true && !status.terminal;
	const completed = job.status === 'completed' || job.status === 'completed_with_warnings';
	if (completed) {
		return {
			canViewIndex: true,
			canTestSearch: true,
			canCancel: false,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: null
		};
	}
	if (job.status === 'cancelled') {
		return {
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: true,
			canEnterRetryKey: false,
			retryCopy: null
		};
	}
	if (!status.terminal) {
		return {
			canViewIndex: false,
			canTestSearch: false,
			canCancel,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: null
		};
	}
	if (job.publicationDisposition === 'unknown') {
		if (capabilities?.resume !== true) {
			return NO_JOB_ACTIONS;
		}
		return {
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: 'Retry is blocked until destination reconciliation is complete.'
		};
	}
	if (!job.resumable) {
		return {
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: true,
			canEnterRetryKey: false,
			retryCopy: null
		};
	}
	if (capabilities?.resume !== true) {
		return NO_JOB_ACTIONS;
	}
	const admissionPresentation = describeAlgoliaImportAdmission(admission);
	if (admissionPresentation.disablesStarts) {
		return {
			canViewIndex: false,
			canTestSearch: false,
			canCancel: false,
			canResume: false,
			canStartNewImport: false,
			canEnterRetryKey: false,
			retryCopy: admissionPresentation.message
		};
	}
	return {
		canViewIndex: false,
		canTestSearch: false,
		canCancel: false,
		canResume:
			capabilities?.resume === true && (job.status === 'failed' || job.status === 'interrupted'),
		canStartNewImport: false,
		canEnterRetryKey: true,
		retryCopy:
			capabilities?.resume === true
				? `Reconnect to ${migrationSourceProviderLabel(job.sourceProvider)} with a fresh key. Already-imported records are skipped when the import resumes.`
				: `Reconnect to ${migrationSourceProviderLabel(job.sourceProvider)} with a fresh key before retrying.`
	};
}

export function algoliaImportCompatibilityWarning(job: PublicAlgoliaImportJob): string | null {
	return algoliaImportCompatibilityWarningPresentation(job)?.summary ?? null;
}

export function algoliaImportCompatibilityWarningPresentation(
	job: PublicAlgoliaImportJob
): AlgoliaImportCompatibilityWarningPresentation | null {
	if (job.warnings.length === 0) {
		return null;
	}
	return {
		summary: compatibilityWarningSummary(job),
		groups: groupedCompatibilityWarnings(job.warnings)
	};
}

export function migrationPreviewCompatibilityWarningPresentation(
	preview: MigrationPreviewResponse
): AlgoliaImportCompatibilityWarningPresentation | null {
	if (preview.report.entries.length === 0) {
		return null;
	}
	return {
		summary: previewCompatibilitySummary(preview),
		groups: groupedCompatibilityWarnings(
			preview.report.entries.map((entry) => ({
				resource: entry.resource,
				code: entry.code,
				message: '',
				severity: previewSeverityLabel(entry.severity),
				pageIndex: entry.pageIndex,
				itemIndex: entry.itemIndex,
				jsonPath: entry.jsonPath
			}))
		)
	};
}

export function algoliaImportIndexHref(target: string): `/console/indexes/${string}` {
	return `/console/indexes/${encodeURIComponent(String(target))}`;
}

export function algoliaImportSearchHref(target: string): `/console/indexes/${string}?tab=search` {
	return `${algoliaImportIndexHref(target)}?tab=search`;
}

const MAX_WARNING_FIELD_LENGTH = 80;

function compatibilityWarningSummary(job: PublicAlgoliaImportJob): string {
	if (job.status === 'completed_with_warnings' && job.terminalOutcomeObserved) {
		return `Import completed with ${job.warnings.length} compatibility ${pluralize(
			'warning',
			job.warnings.length
		)}.`;
	}
	return `This import has ${job.warnings.length} compatibility ${pluralize(
		'warning',
		job.warnings.length
	)}.`;
}

function previewCompatibilitySummary(preview: MigrationPreviewResponse): string {
	const { totalEntries, hardRejections, warnings, scopeGaps } = preview.report.summary;
	return `Preview found ${totalEntries} compatibility ${pluralize(
		'finding',
		totalEntries
	)}: ${joinPreviewSummaryParts([
		[hardRejections, 'hard rejection'],
		[warnings, 'warning'],
		[scopeGaps, 'scope gap']
	])}.`;
}

function joinPreviewSummaryParts(parts: Array<[number, string]>): string {
	const visible = parts
		.filter(([count]) => count > 0)
		.map(([count, label]) => `${count} ${pluralize(label, count)}`);
	if (visible.length <= 1) {
		return visible[0] ?? '0 findings';
	}
	if (visible.length === 2) {
		return `${visible[0]} and ${visible[1]}`;
	}
	return `${visible.slice(0, -1).join(', ')}, and ${visible[visible.length - 1]}`;
}

function previewSeverityLabel(
	severity: MigrationPreviewResponse['report']['entries'][number]['severity']
): string {
	switch (severity) {
		case 'HardRejection':
			return 'Hard rejection';
		case 'ScopeGap':
			return 'Scope gap';
		case 'Warning':
			return 'Warning';
	}
}

type CompatibilityWarning = Omit<AlgoliaImportWarning, 'pageIndex' | 'itemIndex'> & {
	pageIndex?: number | null;
	itemIndex?: number | null;
	severity?: string;
};

function groupedCompatibilityWarnings(
	warnings: CompatibilityWarning[]
): AlgoliaImportCompatibilityWarningGroup[] {
	const groups = new Map<string, AlgoliaImportCompatibilityWarningGroup>();
	for (const warning of warnings) {
		let group = groups.get(warning.resource);
		if (group === undefined) {
			group = {
				resource: warning.resource,
				resourceLabel: warningIdentifier(warning.resource, 'configuration'),
				warnings: []
			};
			groups.set(warning.resource, group);
		}
		group.warnings.push({
			code: boundedWarningField(warning.code, 'compatibility warning'),
			message: boundedWarningField(warning.message, 'Compatibility warning'),
			...(warning.severity === undefined ? {} : { severity: warning.severity }),
			locator: compatibilityWarningLocator(warning)
		});
	}
	return Array.from(groups.values());
}

function compatibilityWarningLocator(warning: CompatibilityWarning): string | null {
	const locations: string[] = [];
	if (warning.pageIndex != null) {
		locations.push(`page ${warning.pageIndex}`);
	}
	if (warning.itemIndex != null) {
		locations.push(`item ${warning.itemIndex}`);
	}
	if (warning.jsonPath !== '') {
		locations.push(`path ${boundedWarningField(warning.jsonPath, '$')}`);
	}
	return locations.length === 0 ? null : locations.join(', ');
}

function warningIdentifier(value: string, fallback: string): string {
	const humanized = value.replace(/[_-]+/g, ' ').replace(/\s+/g, ' ').trim();
	return boundedWarningField(humanized, fallback);
}

function boundedWarningField(value: string, fallback: string): string {
	const presentValue = value === '' ? fallback : value;
	const characters = Array.from(presentValue);
	return characters.length <= MAX_WARNING_FIELD_LENGTH
		? presentValue
		: `${characters.slice(0, MAX_WARNING_FIELD_LENGTH - 1).join('')}…`;
}

function pluralize(noun: string, count: number): string {
	return count === 1 ? noun : `${noun}s`;
}
