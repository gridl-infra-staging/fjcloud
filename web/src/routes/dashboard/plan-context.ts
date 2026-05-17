import type { CustomerProfileResponse, OnboardingStatus } from '$lib/api/types';

export type DashboardFreeTierLimits = {
	max_searches_per_month: number;
	max_records: number;
	max_storage_mb: number;
	max_indexes: number;
};

export type DashboardPlanContext = {
	billing_plan: 'free' | 'shared';
	free_tier_limits: DashboardFreeTierLimits | null;
	has_payment_method: boolean | null;
	onboarding_completed: boolean | null;
	onboarding_status_loaded: boolean;
};

function normalizeFreeTierLimits(
	limits: OnboardingStatus['free_tier_limits']
): DashboardFreeTierLimits | null {
	if (!limits) {
		return null;
	}

	return {
		max_searches_per_month: limits.max_searches_per_month,
		max_records: limits.max_records,
		max_storage_mb: limits.max_storage_mb,
		max_indexes: limits.max_indexes
	};
}

export const fallbackDashboardPlanContext: DashboardPlanContext = {
	billing_plan: 'free',
	free_tier_limits: null,
	has_payment_method: null,
	onboarding_completed: null,
	onboarding_status_loaded: false
};

export function buildDashboardPlanContext(
	profile: CustomerProfileResponse | null,
	onboardingStatus: OnboardingStatus | null
): DashboardPlanContext {
	return {
		billing_plan: onboardingStatus?.billing_plan ?? profile?.billing_plan ?? 'free',
		free_tier_limits: normalizeFreeTierLimits(onboardingStatus?.free_tier_limits ?? null),
		has_payment_method: onboardingStatus?.has_payment_method ?? null,
		onboarding_completed: onboardingStatus?.completed ?? null,
		onboarding_status_loaded: onboardingStatus !== null
	};
}
