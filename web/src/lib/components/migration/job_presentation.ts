import type {
	AlgoliaImportJobStatus,
	AlgoliaMigrationCapabilities,
	PublicAlgoliaImportError,
	PublicAlgoliaImportJob
} from '$lib/api/types';

export type AlgoliaImportStatusPresentation = {
	status: AlgoliaImportJobStatus;
	label: string;
	phase: string;
	running: boolean;
	terminal: boolean;
};

export type AlgoliaImportSummaryRow = {
	label: 'Documents' | 'Settings' | 'Synonyms' | 'Rules';
	imported: number;
	expected: number;
	rejected: number;
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

const ERROR_COPY: Record<PublicAlgoliaImportError['code'], string> = {
	invalid_credentials: 'Algolia credentials were rejected. Reconnect with a valid key.',
	missing_source_permission: 'The Algolia key does not have permission to read the source index.',
	source_not_found: 'The source index could not be found.',
	source_catalog_too_large: 'The Algolia source catalog is too large to import.',
	destination_conflict: 'The destination index conflicts with another import.',
	quota_exceeded: 'The import exceeds the destination quota.',
	source_too_large: 'The source index is too large to import.',
	insufficient_engine_storage: 'The destination does not have enough storage for this import.',
	destination_changed: 'The destination changed while the import was running.',
	source_changed: 'The source changed while the import was running.',
	incompatible_data: 'Some source data is not compatible with the destination.',
	engine_upgrade_required: 'The destination must be upgraded before this import can continue.',
	migration_ha_not_supported: 'This import is not supported for high-availability destinations.',
	migration_provider_unsupported: 'This destination provider does not support Algolia imports.',
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

export function describeAlgoliaImportError(error: PublicAlgoliaImportError | null): string | null {
	return error === null ? null : ERROR_COPY[error.code];
}

export function algoliaImportSummaryRows(job: PublicAlgoliaImportJob): AlgoliaImportSummaryRow[] {
	const { summary } = job;
	return [
		{
			label: 'Documents',
			imported: summary.documentsImported,
			expected: summary.documentsExpected,
			rejected: summary.documentsRejected
		},
		{
			label: 'Settings',
			imported: summary.settingsApplied,
			expected: summary.settingsApplied + summary.settingsUnsupported,
			rejected: summary.settingsUnsupported
		},
		{
			label: 'Synonyms',
			imported: summary.synonymsImported,
			expected: summary.synonymsExpected,
			rejected: summary.synonymsRejected
		},
		{
			label: 'Rules',
			imported: summary.rulesImported,
			expected: summary.rulesExpected,
			rejected: summary.rulesRejected
		}
	];
}

export function describeAlgoliaImportPublicationDisposition(
	job: PublicAlgoliaImportJob
): AlgoliaImportDispositionPresentation {
	if (job.mode === 'replace' && job.error?.code === 'destination_changed') {
		return {
			tone: 'danger',
			message:
				'Replacement stopped because the destination changed. Legitimate destination document or configuration writes were preserved; retry only after both Algolia and fjcloud are quiet and with a new blank Algolia key.'
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
				? 'Reconnect to Algolia with a fresh key. Already-imported records are skipped when the import resumes.'
				: 'Reconnect to Algolia with a fresh key before retrying.'
	};
}

export function algoliaImportCompatibilityWarning(job: PublicAlgoliaImportJob): string | null {
	const rejectedRows = algoliaImportSummaryRows(job).filter((row) => row.rejected > 0);
	if (rejectedRows.length === 0) {
		return null;
	}
	return `${formatRejectedRows(rejectedRows)} could not be imported.`;
}

export function algoliaImportIndexHref(target: string): `/console/indexes/${string}` {
	return `/console/indexes/${encodeURIComponent(String(target))}`;
}

export function algoliaImportSearchHref(target: string): `/console/indexes/${string}?tab=search` {
	return `${algoliaImportIndexHref(target)}?tab=search`;
}

function formatRejectedRows(rows: AlgoliaImportSummaryRow[]): string {
	const parts = rows.map((row) => `${row.rejected} ${singularize(row.label, row.rejected)}`);
	if (parts.length === 1) {
		return parts[0];
	}
	if (parts.length === 2) {
		return `${parts[0]} and ${parts[1]}`;
	}
	return `${parts.slice(0, -1).join(', ')}, and ${parts[parts.length - 1]}`;
}

function singularize(label: AlgoliaImportSummaryRow['label'], count: number): string {
	const lower = label.toLowerCase();
	if (count !== 1) {
		return lower;
	}
	if (label === 'Synonyms') {
		return 'synonym';
	}
	return lower.slice(0, -1);
}
