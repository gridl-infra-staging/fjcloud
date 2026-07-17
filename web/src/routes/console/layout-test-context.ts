import type { CustomerProfileResponse, OnboardingStatus } from '$lib/api/types';

export const layoutTestProfile: CustomerProfileResponse = {
	id: 'cust-1',
	name: 'Test User',
	email: 'test@example.com',
	email_verified: true,
	billing_plan: 'free',
	created_at: '2026-01-01T00:00:00Z'
};

export const layoutTestOnboarding: OnboardingStatus = {
	has_payment_method: false,
	has_region: false,
	region_ready: false,
	has_index: false,
	has_api_key: false,
	completed: false,
	billing_plan: 'free',
	free_tier_limits: null,
	flapjack_url: null,
	suggested_next_step: ''
};

export const layoutTestPlanContext = {
	billing_plan: 'free' as const,
	free_tier_limits: null,
	has_payment_method: false,
	onboarding_completed: false,
	onboarding_status_loaded: true
};

export const layoutTestDefaults = {
	profile: layoutTestProfile,
	onboardingStatus: layoutTestOnboarding,
	planContext: layoutTestPlanContext,
	freeTierProgress: null,
	impersonation: null
};
