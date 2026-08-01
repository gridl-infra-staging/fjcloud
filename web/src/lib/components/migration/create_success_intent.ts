import type { PublicAlgoliaImportJob, SourceProvider } from '$lib/api/types';

export type MigrationCreateSuccessIntent = {
	jobId: string;
	href: `/console/migrate/${string}?source_provider=${SourceProvider}`;
};

const SOURCE_PROVIDER_LABELS: Record<SourceProvider, string> = {
	algolia: 'Algolia',
	meilisearch: 'Meilisearch',
	typesense: 'Typesense'
};

export function migrationSourceProviderLabel(sourceProvider: SourceProvider): string {
	return SOURCE_PROVIDER_LABELS[sourceProvider];
}

export function migrationJobHref(
	jobId: string,
	sourceProvider: SourceProvider
): `/console/migrate/${string}?source_provider=${SourceProvider}` {
	return `/console/migrate/${encodeURIComponent(jobId)}?source_provider=${sourceProvider}`;
}

export function migrationCreateSuccessIntent(
	job: Pick<PublicAlgoliaImportJob, 'id' | 'sourceProvider'>
): MigrationCreateSuccessIntent {
	return {
		jobId: job.id,
		href: migrationJobHref(job.id, job.sourceProvider)
	};
}
