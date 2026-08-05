import { fail, type ActionFailure } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { ApiRequestError } from '$lib/api/client';
import type {
	AlgoliaDestinationEligibilityRequest,
	AlgoliaMigrationAvailabilityResponse,
	CreateMigrationImportJobRequest,
	ListMigrationSourceIndexesRequest,
	MigrationPreviewArguments,
	MigrationPreviewRequest,
	MigrationPreviewSourceProvider,
	PublicAlgoliaImportJobPage,
	SourceProvider
} from '$lib/api/types';
import { MIGRATION_PREVIEW_SOURCE_PROVIDERS, isSourceProvider } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure,
	type DashboardSessionExpiredPayload
} from '$lib/server/auth-action-errors';
import { privateEnvValue } from '$lib/server/runtime-env';

const MIGRATION_ACTION_FAILED = 'Migration request failed';
const RECENT_IMPORTS_FAILED = 'Recent imports could not be loaded';
const RECENT_IMPORTS_PAGE_SIZE = 10;
const INVALID_PAYLOAD_MESSAGE = 'Invalid payload';
const SOURCE_PROVIDER_UNSUPPORTED = 'source_provider_unsupported';
const INVALID_SOURCE_HOST_MESSAGE = 'Host URL must be a public https origin';
const INVALID_IDEMPOTENCY_KEY_MESSAGE = 'Invalid idempotency key';
const DEFAULT_SOURCE_PROVIDER: SourceProvider = 'algolia';
const MAX_IDEMPOTENCY_KEY_LENGTH = 128;
const IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9._:-]+$/;
const LOOPBACK_HOSTNAMES = new Set(['127.0.0.1', '::1', 'localhost']);

const UNAVAILABLE_AVAILABILITY: AlgoliaMigrationAvailabilityResponse = {
	available: false,
	reason: 'temporarily_unavailable',
	message: 'Algolia migration is temporarily unavailable while we replace the importer.',
	capabilities: { cancel: false, resume: false, replace: false, preview: false, verify: false }
};

type ServerApiClient = ReturnType<typeof createApiClient>;
type SessionFailure = ActionFailure<DashboardSessionExpiredPayload>;

class SourceProviderUnsupportedError extends Error {}
class InvalidSourceHostError extends Error {}
class InvalidIdempotencyKeyError extends Error {}

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
	api: ServerApiClient,
	sourceProvider: SourceProvider
): Promise<RecentImportsPayload | SessionFailure> {
	try {
		const page = await api.listMigrationImportJobs(sourceProvider, {
			limit: RECENT_IMPORTS_PAGE_SIZE
		});
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
		availability = await api.getMigrationAvailability(DEFAULT_SOURCE_PROVIDER);
	} catch (err) {
		const sessionFailure = mapDashboardSessionFailure(err);
		if (sessionFailure) return sessionFailure;
		return { availability: UNAVAILABLE_AVAILABILITY, recentImports: EMPTY_RECENT_IMPORTS };
	}

	const recentImports = availability.available
		? await loadRecentImports(api, DEFAULT_SOURCE_PROVIDER)
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

function migrationPayloadFromFormData<T>(data: FormData): {
	sourceProvider: SourceProvider;
	payload: T;
} {
	const parsed = payloadFromFormData<T & { source_provider?: unknown }>(data);
	if (!isSourceProvider(parsed.source_provider)) {
		throw new SourceProviderUnsupportedError();
	}
	const { source_provider: sourceProvider, ...payload } = parsed;
	return { sourceProvider, payload: payload as T };
}

function validatedHostedSourceOrigin(value: string): string {
	let parsed: URL;
	try {
		parsed = new URL(value.trim());
	} catch {
		throw new InvalidSourceHostError();
	}

	const hostname = parsed.hostname.toLowerCase();
	const loopbackHostname = hostname.replace(/^\[|\]$/g, '');
	const hasExplicitPort = parsed.port !== '' && parsed.port !== '443';
	const isIpLiteral = /^[\d.:]+$/.test(hostname);
	const shapeRejected =
		parsed.username !== '' ||
		parsed.password !== '' ||
		parsed.search !== '' ||
		parsed.hash !== '' ||
		parsed.pathname !== '/';
	const publicRejected =
		parsed.protocol !== 'https:' ||
		hasExplicitPort ||
		isIpLiteral ||
		hostname === 'localhost' ||
		hostname.endsWith('.localhost') ||
		!hostname.includes('.');
	const flagEnabled = privateEnvValue('FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS') === '1';
	// Local development imports may point at a loopback search service, but the
	// opt-in is private server config and must never make RFC1918 or metadata
	// hosts client-admissible.
	const loopbackAdmitted =
		flagEnabled &&
		LOOPBACK_HOSTNAMES.has(loopbackHostname) &&
		(parsed.protocol === 'http:' || parsed.protocol === 'https:');
	if (shapeRejected || (publicRejected && !loopbackAdmitted)) {
		throw new InvalidSourceHostError();
	}

	return parsed.origin;
}

function sanitizeHostedSourceField<T>(
	sourceProvider: SourceProvider,
	payload: T,
	field: 'host' | 'endpoint'
): T {
	if (sourceProvider === 'algolia') {
		return payload;
	}
	if (typeof payload !== 'object' || payload === null || !(field in payload)) {
		throw new InvalidSourceHostError();
	}
	const value = (payload as Partial<Record<'host' | 'endpoint', unknown>>)[field];
	if (typeof value !== 'string') {
		throw new InvalidSourceHostError();
	}
	return {
		...payload,
		[field]: validatedHostedSourceOrigin(value)
	} as T;
}

function sanitizeHostedSourcePayload<T>(sourceProvider: SourceProvider, payload: T): T {
	return sanitizeHostedSourceField(sourceProvider, payload, 'host');
}

function sanitizePreviewPayload(
	sourceProvider: SourceProvider,
	payload: MigrationPreviewRequest
): MigrationPreviewRequest {
	return sanitizeHostedSourceField(sourceProvider, payload, 'endpoint');
}

function isMigrationPreviewSourceProvider(
	sourceProvider: SourceProvider
): sourceProvider is MigrationPreviewSourceProvider {
	return (MIGRATION_PREVIEW_SOURCE_PROVIDERS as readonly SourceProvider[]).includes(sourceProvider);
}

function validatedIdempotencyKey(value: FormDataEntryValue | null): string {
	if (typeof value !== 'string') {
		throw new InvalidIdempotencyKeyError('Missing idempotency key');
	}
	if (value === '') {
		throw new InvalidIdempotencyKeyError('Missing idempotency key');
	}
	if (value.length > MAX_IDEMPOTENCY_KEY_LENGTH || !IDEMPOTENCY_KEY_PATTERN.test(value)) {
		throw new InvalidIdempotencyKeyError(INVALID_IDEMPOTENCY_KEY_MESSAGE);
	}
	return value;
}

function payloadFailure(error: unknown) {
	if (error instanceof SourceProviderUnsupportedError) {
		return sourceProviderFailure();
	}
	if (error instanceof InvalidSourceHostError) {
		return fail(400, { error: INVALID_SOURCE_HOST_MESSAGE });
	}
	if (
		error instanceof Error &&
		(error.message === 'Missing payload' || error.message === INVALID_PAYLOAD_MESSAGE)
	) {
		return fail(400, { error: error.message });
	}
	return null;
}

function sourceProviderFailure() {
	return fail(400, {
		error: SOURCE_PROVIDER_UNSUPPORTED,
		code: SOURCE_PROVIDER_UNSUPPORTED
	});
}

function upstreamSourceProviderFailure(error: unknown) {
	if (!(error instanceof ApiRequestError) || error.status !== 400) return null;
	if (typeof error.body !== 'object' || error.body === null) return null;
	const body = error.body as Record<string, unknown>;
	if (body.code !== SOURCE_PROVIDER_UNSUPPORTED) return null;
	return sourceProviderFailure();
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
		const providerFailure = upstreamSourceProviderFailure(error);
		if (providerFailure) return providerFailure;
		return fail(400, {
			error: customerFacingErrorMessage(error, MIGRATION_ACTION_FAILED)
		});
	}
}

export const actions: Actions = {
	providerEligibility: async ({ request, locals }) => {
		let sourceProvider: SourceProvider;
		let payload: { region?: unknown };
		try {
			const parsed = migrationPayloadFromFormData<{ region?: unknown }>(await request.formData());
			sourceProvider = parsed.sourceProvider;
			payload = parsed.payload;
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		const region = typeof payload.region === 'string' ? payload.region.trim() : '';
		if (!region) return fail(400, { error: 'Region is required' });

		return runMigrationAction(locals, async (api) => ({
			providerEligibility: await api.checkMigrationDestinationEligibility(sourceProvider, {
				phase: 'provider',
				mode: 'create',
				target: { region, name: '' }
			})
		}));
	},
	availability: async ({ request, locals }) => {
		let sourceProvider: SourceProvider;
		try {
			const parsed = migrationPayloadFromFormData<Record<string, never>>(await request.formData());
			sourceProvider = parsed.sourceProvider;
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			availability: await api.getMigrationAvailability(sourceProvider)
		}));
	},
	checkDestinationEligibility: async ({ request, locals }) => {
		let sourceProvider: SourceProvider;
		let payload: AlgoliaDestinationEligibilityRequest;
		try {
			const parsed = migrationPayloadFromFormData<AlgoliaDestinationEligibilityRequest>(
				await request.formData()
			);
			sourceProvider = parsed.sourceProvider;
			payload = parsed.payload;
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			targetEligibility: await api.checkMigrationDestinationEligibility(sourceProvider, payload)
		}));
	},
	listSourceIndexes: async ({ request, locals }) => {
		let sourceProvider: SourceProvider;
		let payload: ListMigrationSourceIndexesRequest;
		try {
			const parsed = migrationPayloadFromFormData<ListMigrationSourceIndexesRequest>(
				await request.formData()
			);
			sourceProvider = parsed.sourceProvider;
			payload = sanitizeHostedSourcePayload(sourceProvider, parsed.payload);
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			sourceIndexes: await api.listMigrationSourceIndexes(sourceProvider, payload)
		}));
	},
	createImportJob: async ({ request, locals }) => {
		let idempotencyKey: string;
		let sourceProvider: SourceProvider;
		let payload: CreateMigrationImportJobRequest;
		try {
			const data = await request.formData();
			idempotencyKey = validatedIdempotencyKey(data.get('idempotencyKey'));
			const parsed = migrationPayloadFromFormData<CreateMigrationImportJobRequest>(data);
			sourceProvider = parsed.sourceProvider;
			payload = sanitizeHostedSourcePayload(sourceProvider, parsed.payload);
		} catch (error) {
			if (error instanceof InvalidIdempotencyKeyError) {
				return fail(400, { error: error.message });
			}
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			job: await api.createMigrationImportJob(sourceProvider, payload, idempotencyKey)
		}));
	},
	previewImport: async ({ request, locals }) => {
		let sourceProvider: SourceProvider;
		let previewArguments: MigrationPreviewArguments;
		try {
			const parsed = migrationPayloadFromFormData<MigrationPreviewRequest>(
				await request.formData()
			);
			sourceProvider = parsed.sourceProvider;
			if (!isMigrationPreviewSourceProvider(sourceProvider)) return sourceProviderFailure();
			const payload = sanitizePreviewPayload(sourceProvider, parsed.payload);
			previewArguments = [sourceProvider, payload] as MigrationPreviewArguments;
		} catch (error) {
			return payloadFailure(error) ?? fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			preview: await api.previewMigrationImport(...previewArguments)
		}));
	},
	recentImports: async ({ request, locals }) => {
		let sourceProvider: SourceProvider;
		let cursor: string | undefined;
		let limit: number | undefined;
		try {
			const data = await request.formData();
			const rawSourceProvider = data.get('source_provider');
			if (!isSourceProvider(rawSourceProvider)) return sourceProviderFailure();
			sourceProvider = rawSourceProvider;
			cursor = parseCursor(data.get('cursor'));
			limit = parseLimit(data.get('limit'));
		} catch {
			return fail(400, { error: MIGRATION_ACTION_FAILED });
		}
		return runMigrationAction(locals, async (api) => ({
			recentImports: await api.listMigrationImportJobs(sourceProvider, { cursor, limit })
		}));
	}
};
