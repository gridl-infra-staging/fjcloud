import { error, fail, type ActionFailure } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { ApiRequestError } from '$lib/api/client';
import type { AlgoliaMigrationCapabilities, PublicAlgoliaImportJob } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure,
	type DashboardSessionExpiredPayload
} from '$lib/server/auth-action-errors';

const JOB_ACTION_FAILED = 'Algolia migration request failed';
const FAIL_CLOSED_CAPABILITIES: AlgoliaMigrationCapabilities = {
	cancel: false,
	resume: false,
	replace: false
};
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;
const MAX_JOB_ID_LENGTH = 128;

type ServerApiClient = ReturnType<typeof createApiClient>;
type SessionFailure = ActionFailure<DashboardSessionExpiredPayload>;

function validatedJobId(jobId: string): string {
	if (
		jobId === '' ||
		jobId.length > MAX_JOB_ID_LENGTH ||
		jobId.trim() !== jobId ||
		jobId.includes('/') ||
		jobId.includes('\\') ||
		CONTROL_CHARACTERS.test(jobId)
	) {
		throw error(404, 'Import job not found');
	}
	return jobId;
}

function isSessionFailure(value: unknown): value is SessionFailure {
	return (
		typeof value === 'object' &&
		value !== null &&
		'data' in value &&
		typeof (value as { data?: unknown }).data === 'object' &&
		(value as { data: Record<string, unknown> }).data?._authSessionExpired === true
	);
}

// The job is the route's single source of truth. Auth failures fold into the
// shared dashboard session contract; a genuinely missing job is a 404. Any other
// job failure is a server error rather than a silent empty page.
async function loadJob(
	api: ServerApiClient,
	jobId: string
): Promise<PublicAlgoliaImportJob | SessionFailure> {
	try {
		return await api.getAlgoliaImportJob(jobId);
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		if (err instanceof ApiRequestError && err.status === 404) {
			throw error(404, 'Import job not found');
		}
		throw error(500, 'Failed to load import job');
	}
}

// Availability is the single capability source. It fails closed for any non-auth
// failure or an unavailable contract, so the detail page can never surface a
// cancel/resume/replace control the platform has not actually enabled.
async function loadCapabilities(
	api: ServerApiClient
): Promise<AlgoliaMigrationCapabilities | SessionFailure> {
	try {
		const availability = await api.getAlgoliaMigrationAvailability();
		return availability.available ? availability.capabilities : FAIL_CLOSED_CAPABILITIES;
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return FAIL_CLOSED_CAPABILITIES;
	}
}

export const load: PageServerLoad = async ({ params, locals }) => {
	const api = createApiClient(locals.user?.token);
	const jobId = validatedJobId(params.jobId);

	const job = await loadJob(api, jobId);
	if (isSessionFailure(job)) return job;

	const capabilities = await loadCapabilities(api);
	if (isSessionFailure(capabilities)) return capabilities;

	return { job, capabilities };
};

async function runJobAction(
	locals: App.Locals,
	operation: (api: ServerApiClient) => Promise<PublicAlgoliaImportJob>
) {
	const api = createApiClient(locals.user?.token);
	try {
		return { job: await operation(api) };
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return fail(400, { error: customerFacingErrorMessage(err, JOB_ACTION_FAILED) });
	}
}

export const actions: Actions = {
	cancel: async ({ params, locals }) => {
		const jobId = validatedJobId(params.jobId);
		return runJobAction(locals, (api) => api.cancelAlgoliaImportJob(jobId));
	},
	resume: async ({ params, request, locals }) => {
		const jobId = validatedJobId(params.jobId);
		const data = await request.formData();
		const rawApiKey = data.get('apiKey');
		const apiKey = typeof rawApiKey === 'string' ? rawApiKey.trim() : '';
		if (apiKey === '') {
			return fail(400, { error: 'Algolia API key is required' });
		}
		return runJobAction(locals, (api) => api.resumeAlgoliaImportJob(jobId, { apiKey }));
	}
};
