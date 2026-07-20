export const EXPECTED_MIGRATION_LOG_EXCLUSION_OPERATIONS = [
	'connect',
	'list',
	'start',
	'status',
	'history',
	'cancel',
	'resume'
] as const;

export const MIGRATION_LOG_EXCLUSION_MATRIX = [
	{ operation: 'connect', route: '/migration/algolia/connect', method: 'POST' },
	{ operation: 'list', route: '/migration/algolia/list-indexes', method: 'POST' },
	{ operation: 'start', route: '/migration/algolia/jobs', method: 'POST' },
	{ operation: 'status', route: '/migration/algolia/jobs/job_123', method: 'GET' },
	{ operation: 'history', route: '/migration/algolia/jobs?cursor=opaque-history', method: 'GET' },
	{ operation: 'cancel', route: '/migration/algolia/jobs/job_123/cancel', method: 'POST' },
	{ operation: 'resume', route: '/migration/algolia/jobs/job_123/resume', method: 'POST' }
] as const;
