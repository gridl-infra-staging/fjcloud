import type { PublicAlgoliaImportJob } from '$lib/api/types';

export type MigrationCreateSuccessIntent = {
	jobId: string;
	href: `/console/migrate/${string}`;
};

export function migrationJobHref(jobId: string): `/console/migrate/${string}` {
	return `/console/migrate/${encodeURIComponent(jobId)}`;
}

export function migrationCreateSuccessIntent(
	job: Pick<PublicAlgoliaImportJob, 'id'>
): MigrationCreateSuccessIntent {
	return {
		jobId: job.id,
		href: migrationJobHref(job.id)
	};
}
