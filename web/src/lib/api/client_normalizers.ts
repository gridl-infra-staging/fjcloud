import type {
	AlgoliaMigrationAvailabilityResponse,
	AlgoliaMigrationAvailabilityWire,
	AlgoliaMigrationCapabilities,
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
		replace: payload.capabilities?.replace === true
	};

	return {
		...payload,
		capabilities
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
