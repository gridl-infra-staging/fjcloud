import type { CustomerProfileResponse, FreeTierLimits, OnboardingStatus } from '$lib/api/types';

export type DashboardPlanContext = {
	billing_plan: 'free' | 'shared';
	free_tier_limits: FreeTierLimits | null;
	has_payment_method: boolean | null;
	onboarding_completed: boolean | null;
	onboarding_status_loaded: boolean;
};

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
		free_tier_limits: onboardingStatus?.free_tier_limits ?? null,
		has_payment_method: onboardingStatus?.has_payment_method ?? null,
		onboarding_completed: onboardingStatus?.completed ?? null,
		onboarding_status_loaded: onboardingStatus !== null
	};
}
