import type {
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaMigrationAvailabilityWire,
	AlgoliaMigrationCapabilities,
	AlgoliaIndexMetadata,
	AlgoliaSourceListResponse,
	FreeTierLimits,
	ListAlgoliaIndexesRequest,
	OnboardingStatus
} from './types';

type LegacyFreeTierLimits = Omit<FreeTierLimits, 'max_storage_mb'> & {
	max_storage_mb?: number;
	max_storage_gb?: number;
};

export type LegacyOnboardingStatus = Omit<OnboardingStatus, 'free_tier_limits'> & {
	free_tier_limits: LegacyFreeTierLimits | null;
};

function normalizeStorageLimitMb(freeTierLimits: LegacyFreeTierLimits): number {
	if (
		typeof freeTierLimits.max_storage_mb === 'number' &&
		Number.isFinite(freeTierLimits.max_storage_mb)
	) {
		return freeTierLimits.max_storage_mb;
	}
	if (
		typeof freeTierLimits.max_storage_gb === 'number' &&
		Number.isFinite(freeTierLimits.max_storage_gb)
	) {
		return Math.round(freeTierLimits.max_storage_gb * 1024);
	}
	throw new Error('Onboarding free-tier limits must include max_storage_mb or max_storage_gb');
}

export function normalizeOnboardingStatus(payload: LegacyOnboardingStatus): OnboardingStatus {
	if (!payload.free_tier_limits) {
		return {
			...payload,
			free_tier_limits: null
		};
	}

	return {
		...payload,
		free_tier_limits: {
			max_searches_per_month: payload.free_tier_limits.max_searches_per_month,
			max_records: payload.free_tier_limits.max_records,
			max_storage_mb: normalizeStorageLimitMb(payload.free_tier_limits),
			max_indexes: payload.free_tier_limits.max_indexes
		}
	};
}

export function normalizeAlgoliaMigrationAvailability(
	payload: AlgoliaMigrationAvailabilityWire
): AlgoliaMigrationAvailabilityResponse {
	const capabilities: AlgoliaMigrationCapabilities = {
		cancel: payload.capabilities?.cancel === true,
		resume: payload.capabilities?.resume === true,
		replace: payload.capabilities?.replace === true,
		preview: payload.capabilities?.preview === true,
		verify: payload.capabilities?.verify === true
	};

	const response = {
		available: payload.available === true,
		message: payload.message,
		capabilities
	};

	if (payload.reason == null) {
		return response;
	}

	return {
		...response,
		reason: payload.reason
	};
}

export function algoliaSourceListRequest(
	request: ListAlgoliaIndexesRequest
): ListAlgoliaIndexesRequest {
	return {
		appId: request.appId,
		apiKey: request.apiKey,
		...(request.cursor != null ? { cursor: request.cursor } : {}),
		...(request.hitsPerPage != null ? { hitsPerPage: request.hitsPerPage } : {})
	};
}

type HostedSourceIndexSummary = {
	name: string;
	entries?: number | null;
	documentCount?: number | null;
	updatedAt?: string | null;
	revision?: string | null;
	primaryKey?: string | null;
};

type HostedSourceListResponse = {
	indexes: HostedSourceIndexSummary[];
	limit?: number | null;
	offset?: number | null;
	total?: number | null;
};

function isHostedSourceListResponse(payload: unknown): payload is HostedSourceListResponse {
	return (
		typeof payload === 'object' &&
		payload !== null &&
		Array.isArray((payload as Partial<HostedSourceListResponse>).indexes)
	);
}

function normalizeHostedSourceIndex(index: HostedSourceIndexSummary): AlgoliaIndexMetadata {
	const entries = index.documentCount ?? index.entries ?? 0;
	return {
		name: index.name,
		entries,
		dataSize: 0,
		fileSize: 0,
		updatedAt: index.updatedAt ?? '',
		lastBuildTimeS: 0,
		pendingTask: false,
		primary: null,
		replicas: [],
		...(index.revision == null ? {} : { revision: index.revision })
	};
}

function hostedNextCursor(response: HostedSourceListResponse): string | null {
	if (
		typeof response.offset !== 'number' ||
		typeof response.limit !== 'number' ||
		typeof response.total !== 'number'
	) {
		return null;
	}
	const nextOffset = response.offset + response.limit;
	return nextOffset > response.offset && nextOffset < response.total ? String(nextOffset) : null;
}

export function normalizeMigrationSourceListResponse(
	payload: AlgoliaSourceListResponse | HostedSourceListResponse
): AlgoliaSourceListResponse {
	if (!isHostedSourceListResponse(payload)) {
		return payload;
	}
	return {
		items: payload.indexes.map(normalizeHostedSourceIndex),
		nextCursor: hostedNextCursor(payload)
	};
}
