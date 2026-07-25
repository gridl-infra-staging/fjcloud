import { fail, type ActionFailure } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaMigrationAvailabilityResponse,
	CreateAlgoliaImportJobRequest,
	ListAlgoliaIndexesRequest,
	PublicAlgoliaImportJobPage
} from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure,
	type DashboardSessionExpiredPayload
} from '$lib/server/auth-action-errors';

const MIGRATION_ACTION_FAILED = 'Algolia migration request failed';
const RECENT_IMPORTS_FAILED = 'Recent imports could not be loaded';
const RECENT_IMPORTS_PAGE_SIZE = 10;
const INVALID_PAYLOAD_MESSAGE = 'Invalid payload';

const UNAVAILABLE_AVAILABILITY: AlgoliaMigrationAvailabilityResponse = {
	available: false,
	reason: 'temporarily_unavailable',
	message: 'Algolia migration is temporarily unavailable while we replace the importer.',
	capabilities: { cancel: false, resume: false, replace: false }
};

type ServerApiClient = ReturnType<typeof createApiClient>;
type SessionFailure = ActionFailure<DashboardSessionExpiredPayload>;

// SSR payload for the recent-import list. A failure never blocks the create
// flow or the availability branch: it collapses to a retryable list error the
// customer can retry from the browser without a credential ever crossing SSR.
interface RecentImportsPayload {
	page: PublicAlgoliaImportJobPage | null;
	error: string | null;
}

const EMPTY_RECENT_IMPORTS: RecentImportsPayload = { page: null, error: null };

function isSessionFailure(value: unknown): value is SessionFailure {
	return (
		typeof value === 'object' &&
		value !== null &&
		'data' in value &&
		typeof (value as { data?: unknown }).data === 'object' &&
		(value as { data: Record<string, unknown> }).data?._authSessionExpired === true
	);
}

async function loadRecentImports(
	api: ServerApiClient
): Promise<RecentImportsPayload | SessionFailure> {
	try {
		const page = await api.listAlgoliaImportJobs({ limit: RECENT_IMPORTS_PAGE_SIZE });
		return { page, error: null };
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return { page: null, error: customerFacingErrorMessage(err, RECENT_IMPORTS_FAILED) };
	}
}

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	let availability: AlgoliaMigrationAvailabilityResponse;
	try {
		availability = await api.getAlgoliaMigrationAvailability();
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return { availability: UNAVAILABLE_AVAILABILITY, recentImports: EMPTY_RECENT_IMPORTS };
	}

	const recentImports = availability.available
		? await loadRecentImports(api)
		: EMPTY_RECENT_IMPORTS;
	if (isSessionFailure(recentImports)) return recentImports;
	return { availability, recentImports };
};

function parseCursor(value: FormDataEntryValue | null): string | undefined {
	if (typeof value !== 'string') return undefined;
	const trimmed = value.trim();
	return trimmed === '' ? undefined : trimmed;
}

function parseLimit(value: FormDataEntryValue | null): number | undefined {
	if (typeof value !== 'string') return undefined;
	const parsed = Number.parseInt(value, 10);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function payloadFromFormData<T>(data: FormData): T {
	const rawPayload = data.get('payload');
	if (typeof rawPayload !== 'string') {
		throw new Error('Missing payload');
	}
	try {
		return JSON.parse(rawPayload) as T;
	} catch {
		throw new Error(INVALID_PAYLOAD_MESSAGE);
	}
}

async function payloadFromRequest<T>(request: Request): Promise<T> {
	return payloadFromFormData<T>(await request.formData());
}

function payloadFailure(error: unknown) {
	if (
		error instanceof Error &&
		(error.message === 'Missing payload' || error.message === INVALID_PAYLOAD_MESSAGE)
	) {
		return fail(400, { error: error.message });
	}
	return null;
}

async function runMigrationAction<T>(
	locals: App.Locals,
	operation: (api: ReturnType<typeof createApiClient>) => Promise<T>
) {
	const api = createApiClient(locals.user?.token);
	try {
		return await operation(api);
	} catch (error) {
		const sessionFailure = mapDashboardSessionFailure(error);
		if (sessionFailure) return sessionFailure;
		return fail(400, {
			error: customerFacingErrorMessage(error, MIGRATION_ACTION_FAILED)
		});
	}
}

export const actions: Actions = {
	providerEligibility: async ({ request, locals }) => {
		let payload: { region?: unknown };
		try {
			payload = await payloadFromRequest<{ region?: unknown }>(request);
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		const region = typeof payload.region === 'string' ? payload.region.trim() : '';
		if (!region) return fail(400, { error: 'Region is required' });

		return runMigrationAction(locals, async (api) => ({
			providerEligibility: await api.checkAlgoliaDestinationEligibility({
				phase: 'provider',
				mode: 'create',
				target: { region, name: '' }
			})
		}));
	},
	checkDestinationEligibility: async ({ request, locals }) => {
		let payload: AlgoliaDestinationEligibilityRequest;
		try {
			payload = await payloadFromRequest<AlgoliaDestinationEligibilityRequest>(request);
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			targetEligibility: await api.checkAlgoliaDestinationEligibility(payload)
		}));
	},
	listSourceIndexes: async ({ request, locals }) => {
		let payload: ListAlgoliaIndexesRequest;
		try {
			payload = await payloadFromRequest<ListAlgoliaIndexesRequest>(request);
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			sourceIndexes: await api.listAlgoliaSourceIndexes(payload)
		}));
	},
	createImportJob: async ({ request, locals }) => {
		const data = await request.formData();
		const idempotencyKey = data.get('idempotencyKey');
		if (typeof idempotencyKey !== 'string' || idempotencyKey.trim() === '') {
			return fail(400, { error: 'Missing idempotency key' });
		}
		let payload: CreateAlgoliaImportJobRequest;
		try {
			payload = payloadFromFormData<CreateAlgoliaImportJobRequest>(data);
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			job: await api.createAlgoliaImportJob(payload, idempotencyKey)
		}));
	},
	recentImports: async ({ request, locals }) => {
		const data = await request.formData();
		const cursor = parseCursor(data.get('cursor'));
		const limit = parseLimit(data.get('limit'));
		return runMigrationAction(locals, async (api) => ({
			recentImports: await api.listAlgoliaImportJobs({ cursor, limit })
		}));
	}
};
